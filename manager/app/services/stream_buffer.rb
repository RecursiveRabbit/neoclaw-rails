# In-memory ring buffer for Claude Code output per container.
# Stores the last N lines so the stream page can show history
# on load, not just live output.

class StreamBuffer
  MAX_LINES = 500

  class << self
    def append(instance_name, data)
      buffer = buffers[instance_name] ||= []
      buffer << { data: data, at: Time.current.iso8601 }
      buffer.shift while buffer.size > MAX_LINES
    end

    def history(instance_name)
      buffers[instance_name] || []
    end

    def clear(instance_name)
      buffers.delete(instance_name)
    end

    private

    def buffers
      @buffers ||= {}
    end
  end
end
