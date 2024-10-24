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
        worker_pids = []

        # create a mutex to synchronize the server thread
        mutex = Mutex.new

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
                if restart_server.length > 0
                  # acquire a mutex to ensure the server is started before stopping
                  mutex.synchronize do
                    restart_server.clear
                    server.begin_restart(true)
                    @config.run_hooks(:before_refork, nil, @log_writer, @hook_data)
                  end
                end
              elsif idx == 0 # restart server
                restart_server << Puma::Const::WorkerCmd::RESTART << Puma::Const::WorkerCmd::STOPPED
              else
                # spawn new worker
                restart_server << "#{Puma::Const::WorkerCmd::SPAWN}#{idx}"
              end
            end
          end
        end

        Signal.trap "SIGTERM" do
          @worker_write << "#{Puma::Const::PipeRequest::EXTERNAL_TERM}#{Process.pid}\n" rescue nil
          Thread.new do
            # create a new thread to avoid deadlock
            mutex.synchronize do
              restart_server.clear
              server.stop
              restart_server << Puma::Const::WorkerCmd::STOPPED
            end
          end
        end

        begin
          @worker_write << "#{Puma::Const::PipeRequest::BOOT}#{Process.pid}:#{index}\n"
        rescue SystemCallError, IOError
          Puma::Util.purge_interrupt_queue
          STDERR.puts "Master seems to have exited, exiting."
          return
        end

        while (cmd = restart_server.pop) != Puma::Const::WorkerCmd::STOPPED
          server_thread = nil

          # acquire a mutex to synchronize the server thread
          mutex.synchronize do
            if cmd.start_with?(Puma::Const::WorkerCmd::SPAWN) && fork_worker
              # receive the spawn command to fork worker if current worker is worker-0
              idx = cmd.split(Puma::Const::WorkerCmd::SPAWN).last.to_i
              child_pid = spawn_worker(idx)
              worker_pids << child_pid unless child_pid.nil?

            elsif cmd == Puma::Const::WorkerCmd::RESTART
              # receive the restart command to restart the server
              server_thread = server.run

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
                    payload = %Q!#{base_payload}{ "backlog":#{b}, "running":#{r}, "pool_capacity":#{t}, "max_threads":#{m}, "requests_count":#{rc} }\n!
                    io << payload
                  rescue IOError
                    Puma::Util.purge_interrupt_queue
                    break
                  end
                  sleep @options[:worker_check_interval]
                end
              end
              log "Server started - worker #{index}" if @log_writer.debug?
            end
          end

          server_thread&.join if cmd == Puma::Const::WorkerCmd::RESTART
        end

        # Invoke any worker shutdown hooks so they can prevent the worker
        # exiting until any background operations are completed
        @config.run_hooks(:before_worker_shutdown, index, @log_writer, @hook_data)
      ensure
        @worker_write << "#{Puma::Const::PipeRequest::TERM}#{Process.pid}\n" rescue nil
        @worker_write.close
      end

      private

      def spawn_worker(idx)
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
