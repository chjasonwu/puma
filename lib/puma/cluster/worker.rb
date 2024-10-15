# frozen_string_literal: true

module Puma

  class Cluster < Puma::Runner
    #—————————————————————— DO NOT USE — this class is for internal use only ———

    # This class is instantiated by the `Puma::Cluster` and represents a single
    # worker process.
    #
    # At the core of this class is running an instance of `Puma::Server` which
    # gets created via the `start_server` method from the `Puma::Runner` class
    # that this inherits from.
    class Worker < Puma::Runner # :nodoc:
      attr_reader :index, :master

      def initialize(index:, master:, launcher:, pipes:, server: nil)
        super(launcher)

        @index = index
        @master = master
        @check_pipe = pipes[:check_pipe]
        @worker_write = pipes[:worker_write]
        @fork_pipe = pipes[:fork_pipe]
        @wakeup = pipes[:wakeup]
        @server = server
        @hook_data = {}
      end

      def run
        title = "puma: cluster worker #{index}: #{master}"
        title += " [#{@options[:tag]}]" if @options[:tag] && !@options[:tag].empty?
        $0 = title

        Signal.trap "SIGINT", "IGNORE"
        Signal.trap "SIGCHLD", "DEFAULT"

        Thread.new do
          Puma.set_thread_name "wrkr check"
          @check_pipe.wait_readable
          log "! Detected parent died, dying"
          exit! 1
        end

        # for debug purpose only
        use_same_thread = true

        # If we're not running under a Bundler context, then
        # report the info about the context we will be using
        if !ENV['BUNDLE_GEMFILE']
          if File.exist?("Gemfile")
            log "+ Gemfile in context: #{File.expand_path("Gemfile")}"
          elsif File.exist?("gems.rb")
            log "+ Gemfile in context: #{File.expand_path("gems.rb")}"
          end
        end

        # Invoke any worker boot hooks so they can get
        # things in shape before booting the app.
        @config.run_hooks(:before_worker_boot, index, @log_writer, @hook_data)

        log "@server.nil?: #{@server.nil?}\n"
        begin
          server = @server ||= start_server
        rescue Exception => e
          log "! Unable to start worker"
          log e
          log e.backtrace.join("\n    ")
          exit 1
        end

        restart_server = Queue.new << Puma::Const::WorkerCmd::RESTART << Puma::Const::WorkerCmd::STOPPED

        fork_worker = @options[:fork_worker] && index == 0

        # worker ids for validte hang process
        new_workers = Queue.new
        worker_pids = []

        if fork_worker
          restart_server.clear
          Signal.trap "SIGCHLD" do
            wakeup! if worker_pids.reject! do |p|
              Process.wait(p, Process::WNOHANG) rescue true
            end
          end

          Thread.new do
            Puma.set_thread_name "wrkr fork"
            while (idx = @fork_pipe.gets)
              idx = idx.to_i
              if idx == -1 # stop server
                log "wrkr-fork stop server\n"
                if restart_server.length > 0
                  log "stopping server: #{idx}\n"
                  log "server status: #{server.instance_variable_get("@status")}\n"
                  restart_server.clear
                  server.begin_restart(true)
                  log "queue size at shutting down:#{restart_server.length} at now: #{Time.now.to_f}\n"
                  @config.run_hooks(:before_refork, nil, @log_writer, @hook_data)
                end
              elsif idx == 0 # restart server
                log "wrkr-fork restart server\n"
                restart_server << Puma::Const::WorkerCmd::RESTART << Puma::Const::WorkerCmd::STOPPED
                log "queue size at restarting:#{restart_server.length}\n"
              else
                # fork worker
                log "wrkr-fork fork-worker idx:#{idx}\n"

                # new methods, we only queue for later
                if use_same_thread
                  # new_workers << idx
                  restart_server << "#{Puma::Const::WorkerCmd::SPAWN}#{idx}"
                  log "queue size at forking:#{restart_server.length}\n"
                else
                  # previously, we spawn worker when we recv signals
                  worker_pids << pid = spawn_worker(idx)
                  @worker_write << "#{Puma::Const::PipeRequest::FORK}#{pid}:#{idx}\n" rescue nil
                end

              end
            end
          end
        end

        Signal.trap "SIGTERM" do
          log "SIGTERM idx:#{index}-pid:#{Process.pid}\n"
          @worker_write << "#{Puma::Const::PipeRequest::EXTERNAL_TERM}#{Process.pid}\n" rescue nil
          restart_server.clear
          server.stop
          restart_server << Puma::Const::WorkerCmd::STOPPED
        end

        begin
          @worker_write << "#{Puma::Const::PipeRequest::BOOT}#{Process.pid}:#{index}\n"
        rescue SystemCallError, IOError
          Puma::Util.purge_interrupt_queue
          STDERR.puts "Master seems to have exited, exiting."
          return
        end

        while (cmd = restart_server.pop)

          log "cmd:#{cmd}\n"
          break if cmd == Puma::Const::WorkerCmd::STOPPED

          log "restart_server idx:#{index}-pid:#{Process.pid}\n"

          if fork_worker && use_same_thread && cmd.start_with?(Puma::Const::WorkerCmd::SPAWN)
            idx = cmd.split(Puma::Const::WorkerCmd::SPAWN).last.to_i
            # new_worker_pids = spawn_workers(new_workers)
            new_worker_pids = [spawn_worker(idx)]
            log "new_worker_pids: #{new_worker_pids}\n"
            worker_pids.concat(new_worker_pids) unless new_worker_pids.nil?
            log "worker_pids: #{worker_pids}\n"

            next
          end

          log ">>> begin run_server idx:#{index}-pid:#{Process.pid} at now: #{Time.now.to_f}\n"
          server_thread = server.run
          log ">>> end run_server idx:#{index}-pid:#{Process.pid} at now: #{Time.now.to_f}\n"

          if @log_writer.debug? && index == 0
            debug_loaded_extensions "Loaded Extensions - worker 0:"
          end

          stat_thread ||= Thread.new(@worker_write) do |io|
            Puma.set_thread_name "stat pld"
            base_payload = "p#{Process.pid}"

            while true
              begin
                b = server.backlog || 0
                r = server.running || 0
                t = server.pool_capacity || 0
                m = server.max_threads || 0
                rc = server.requests_count || 0
                payload = %Q!#{base_payload}{ "backlog":#{b}, "running":#{r}, "pool_capacity":#{t}, "max_threads": #{m}, "requests_count": #{rc} }\n!
                io << payload
              rescue IOError
                Puma::Util.purge_interrupt_queue
                break
              end
              sleep @options[:worker_check_interval]
            end
          end

          # it takes about 5ms from run server to join
          log "sever_thread about to join: queue size: #{restart_server.length} now: #{Time.now.to_f}\n"
          server_thread.join
          log "sever_thread finish join"
        end

        log "queue is empty"
        # Invoke any worker shutdown hooks so they can prevent the worker
        # exiting until any background operations are completed
        @config.run_hooks(:before_worker_shutdown, index, @log_writer, @hook_data)
      ensure
        log "logic ends"
        @worker_write << "#{Puma::Const::PipeRequest::TERM}#{Process.pid}\n" rescue nil
        @worker_write.close
      end

      private

      def spawn_workers(new_workers)
        worker_pids = []
        begin
          log "waiting spawning"
          while (widx = new_workers.pop(non_block = true))
            log "spawn_sub_workers #{widx}\n"
            worker_pids << pid = spawn_worker(widx)
            # log "f#{pid}:#{widx}\n"
            msg = "#{Puma::Const::PipeRequest::FORK}#{pid}:#{widx}\n"
            log msg
            @worker_write << msg rescue nil
          end
        rescue ThreadError
          log "queue is empty"
        end

        worker_pids
      end

      def spawn_worker(idx)
        log "spawning new worker from worker-0: #{idx}"
        @config.run_hooks(:before_worker_fork, idx, @log_writer, @hook_data)

        pid = fork do
          new_worker = Worker.new index: idx,
                                  master: master,
                                  launcher: @launcher,
                                  pipes: { check_pipe: @check_pipe,
                                           worker_write: @worker_write },
                                  server: @server
          new_worker.run
        end
        log "new worker spawned from worker-0: with pid #{pid}"

        if !pid
          log "! Complete inability to spawn new workers detected"
          log "! Seppuku is the only choice."
          exit! 1
        end

        @config.run_hooks(:after_worker_fork, idx, @log_writer, @hook_data)
        pid
      end
    end
  end
end
