module ActiveRecord::Turntable
  module ClusterHelperMethods
    extend ActiveSupport::Concern

    included do
      ActiveSupport.on_load(:turntable_configuration_loaded) do
        turntable_clusters.each do |name, _cluster|
          turntable_define_cluster_methods(name)
        end
      end
    end

    module ClassMethods
      def force_transaction_all_shards!(options = {}, &block)
        force_connect_all_shards!
        pools = turntable_pool_list
        pools += [ActiveRecord::Base.connection_pool]
        recursive_transaction(pools, options, &block)
      end

      def recursive_transaction(pools, options, &block)
        pool = pools.shift
        if pools.present?
          pool.connection.transaction(**options) do
            recursive_transaction(pools, options, &block)
          end
        else
          pool.connection.transaction(**options, &block)
        end
      end

      def force_connect_all_shards!
        turntable_pool_list.each(&:connection)
      end

      def spec_for(config)
        begin
          require "active_record/connection_adapters/#{config["adapter"]}_adapter"
        rescue LoadError => e
          raise "Please install the #{config["adapter"]} adapter: `gem install activerecord-#{config["adapter"]}-adapter` (#{e})"
        end
        adapter_method = "#{config["adapter"]}_connection"
        ActiveRecord::ConnectionAdapters::ConnectionSpecification.new(config, adapter_method)
      end

      def weighted_random_shard_with(*klasses, &block)
        shards_weight = self.turntable_cluster.weighted_shards(self.current_sequence_value(sequence_name))
        sum = shards_weight.values.inject(&:+)
        idx = rand(sum)
        shard, _weight = shards_weight.find { |_k, v|
          (idx -= v) < 0
        }
        shard ||= shards_weight.keys.first
        self.connection.with_recursive_shards(shard.name, *klasses, &block)
      end

      def all_cluster_transaction(options = {})
        clusters = turntable_clusters.values
        recursive_cluster_transaction(clusters, options) { yield }
      end

      def recursive_cluster_transaction(clusters, options = {}, &block)
        current_cluster = clusters.shift
        current_cluster.shards_transaction([], options) do
          if clusters.present?
            recursive_cluster_transaction(clusters, options, &block)
          else
            yield
          end
        end
      end

      def turntable_define_cluster_methods(cluster_name)
        turntable_define_cluster_class_methods(cluster_name)
      end

      def turntable_define_cluster_class_methods(cluster_name)
        (class << ActiveRecord::Base; self; end).class_eval <<-EOD
          unless respond_to?(:#{cluster_name}_transaction)
            def #{cluster_name}_transaction(shards = [], options = {})
              cluster = turntable_clusters[#{cluster_name.inspect}]
              cluster.shards_transaction(shards, options) { yield }
            end
          end
        EOD
      end
    end
  end
end
