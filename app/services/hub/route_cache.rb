# In-memory route table. The Hub stores nothing on disk.
# { instance_name => { ip:, identity:, room_id:, slug: } }
# Clears on restart. Failed delivery deletes the entry.
# Need status? Ask the relay.

module Hub
  class RouteCache
    @routes = {}
    @resolving = Set.new
    @mutex = Mutex.new

    class << self
      def get(instance_name)
        @mutex.synchronize { @routes[instance_name]&.dup }
      end

      def set(instance_name, ip:, identity:, room_id:, slug:)
        @mutex.synchronize do
          @routes[instance_name] = { ip: ip, identity: identity, room_id: room_id, slug: slug }
        end
      end

      def delete(instance_name)
        @mutex.synchronize do
          @routes.delete(instance_name)
          @resolving.delete(instance_name)
        end
      end

      # Delete all routes pointing at this IP. Used when a singleton pod
      # dies — multiple instance names (hopper-general, hopper-art) may
      # alias the same address.
      def delete_by_ip(ip)
        @mutex.synchronize do
          stale = @routes.select { |_, r| r[:ip] == ip }.keys
          stale.each do |name|
            @routes.delete(name)
            @resolving.delete(name)
          end
          stale
        end
      end

      # Find the route for an identity in a specific room.
      def find_by_identity_and_room(identity_name, room_id)
        @mutex.synchronize do
          @routes.each do |name, route|
            return [name, route.dup] if route[:identity] == identity_name && route[:room_id] == room_id
          end
          nil
        end
      end

      # All routes in a specific room.
      def routes_in_room(room_id)
        @mutex.synchronize do
          @routes.select { |_, r| r[:room_id] == room_id }.map { |name, r| [name, r.dup] }
        end
      end

      def all
        @mutex.synchronize { @routes.transform_values(&:dup) }
      end

      def count
        @mutex.synchronize { @routes.size }
      end

      # Resolve guard — prevents double-spawning while Manager is working.
      def resolving?(instance_name)
        @mutex.synchronize { @resolving.include?(instance_name) }
      end

      def mark_resolving(instance_name)
        @mutex.synchronize { @resolving.add(instance_name) }
      end

      def clear_resolving(instance_name)
        @mutex.synchronize { @resolving.delete(instance_name) }
      end

      def resolving_count
        @mutex.synchronize { @resolving.size }
      end
    end
  end
end
