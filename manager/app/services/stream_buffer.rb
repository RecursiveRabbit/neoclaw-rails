# Ring buffer for Claude Code output per pod.
# Stores the last N lines so the stream page can show history.
# Persists to /data/streams/<instance>.json — survives Manager restarts.

class StreamBuffer
  MAX_LINES = 500
  STREAM_DIR = "/data/streams"

  class << self
    def append(instance_name, data)
      buffer = buffers[instance_name] ||= load(instance_name)
      buffer << { data: data, at: Time.current.iso8601 }
      buffer.shift while buffer.size > MAX_LINES
      save(instance_name, buffer)
    end

    def history(instance_name)
      buffers[instance_name] ||= load(instance_name)
    end

    def clear(instance_name)
      buffers.delete(instance_name)
      FileUtils.rm_f(path_for(instance_name))
    end

    private

    def buffers
      @buffers ||= {}
    end

    def load(instance_name)
      file = path_for(instance_name)
      return [] unless File.exist?(file)
      JSON.parse(File.read(file), symbolize_names: true)
    rescue => e
      Rails.logger.error "StreamBuffer load #{instance_name}: #{e.message}"
      []
    end

    def save(instance_name, buffer)
      FileUtils.mkdir_p(STREAM_DIR)
      File.write(path_for(instance_name), JSON.generate(buffer))
    rescue => e
      Rails.logger.error "StreamBuffer save #{instance_name}: #{e.message}"
    end

    def path_for(instance_name)
      File.join(STREAM_DIR, "#{instance_name}.json")
    end
  end
end
