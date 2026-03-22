# In-memory room cache. Populated from Matrix state events as they arrive.
# { matrix_room_id => { name:, slug:, canonical_alias: } }
# Rebuilds naturally after restart — Synapse re-sends state events on activity.

module Hub
  class Rooms
    @rooms = {}
    @mutex = Mutex.new

    class << self
      # Find or create a room entry. Returns { name:, slug:, canonical_alias: }.
      # slug may be nil if we haven't learned the room's name or alias yet.
      def find_or_create(matrix_room_id, name: nil)
        @mutex.synchronize do
          room = (@rooms[matrix_room_id] ||= {})
          if name && room[:name].nil?
            room[:name] = name
            room[:slug] ||= derive_slug(name)
          end
          room.dup
        end
      end

      def get(matrix_room_id)
        @mutex.synchronize { @rooms[matrix_room_id]&.dup }
      end

      def update_name(matrix_room_id, name)
        @mutex.synchronize do
          room = (@rooms[matrix_room_id] ||= {})
          room[:name] = name
          room[:slug] = derive_slug(name) unless room[:canonical_alias]
        end
      end

      def update_alias(matrix_room_id, canonical_alias)
        @mutex.synchronize do
          room = (@rooms[matrix_room_id] ||= {})
          room[:canonical_alias] = canonical_alias
          room[:slug] = derive_slug(canonical_alias)
        end
      end

      def slug_for(matrix_room_id)
        @mutex.synchronize { @rooms.dig(matrix_room_id, :slug) }
      end

      def count
        @mutex.synchronize { @rooms.size }
      end

      # Find room_id by slug. Returns the first match or nil.
      def room_id_for_slug(slug)
        @mutex.synchronize do
          @rooms.each do |room_id, room|
            return room_id if room[:slug] == slug
          end
          nil
        end
      end

      private

      def derive_slug(source)
        return nil unless source
        result = source.strip.delete_prefix("#").split(":").first.strip
          .gsub(/[^\w\s-]/, "").downcase
          .gsub(/[\s_]+/, "-").gsub(/\A-|-\z/, "")
        result.empty? ? nil : result
      end
    end
  end
end
