# Per-room queue for messages that listeners missed.
#
# When a message has an @mention, listeners are skipped — only the
# target agent gets it. But the reply (from the target) routes to
# listeners, who then lack the context of what was asked.
#
# This queue holds those @mentioned messages. When route_to_listeners
# fires, it flushes the queue and prepends the missed messages as
# context. The listener sees both the question and the answer.
#
# In-memory, like RouteCache. Entries expire after 10 minutes.

module Hub
  class ListenerQueue
    TTL = 600  # 10 minutes

    @queue = {}  # { room_id => [{sender:, content:, at:}] }
    @mutex = Mutex.new

    class << self
      def push(room_id, sender:, content:)
        @mutex.synchronize do
          @queue[room_id] ||= []
          # Prune expired entries while we're here
          cutoff = Time.now - TTL
          @queue[room_id].reject! { |e| e[:at] <= cutoff }
          @queue[room_id] << { sender: sender, content: content, at: Time.now }
        end
      end

      # Return and clear all queued messages for a room.
      # Filters out expired entries.
      def flush(room_id)
        @mutex.synchronize do
          entries = @queue.delete(room_id) || []
          cutoff = Time.now - TTL
          entries.select { |e| e[:at] > cutoff }
        end
      end

      def pending(room_id)
        @mutex.synchronize { (@queue[room_id] || []).size }
      end

      def clear
        @mutex.synchronize { @queue.clear }
      end
    end
  end
end
