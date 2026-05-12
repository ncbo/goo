module SOLR
  module Administration

    def admin_url
      "#{@solr_url}/admin"
    end

    def solr_alive?
      collections_url = URI.parse("#{admin_url}/collections?action=CLUSTERSTATUS")
      http = Net::HTTP.new(collections_url.host, collections_url.port)
      request = Net::HTTP::Get.new(collections_url.request_uri)

      begin
        response = http.request(request)
        return response.code.eql?("200") && JSON.parse(response.body).dig("responseHeader", "status").eql?(0)
      rescue StandardError => e
        return false
      end
    end

    def fetch_all_collections
      collections_url = URI.parse("#{admin_url}/collections?action=LIST")

      http = Net::HTTP.new(collections_url.host, collections_url.port)
      request = Net::HTTP::Get.new(collections_url.request_uri)

      begin
        response = http.request(request)
        raise StandardError, "Failed to fetch collections. HTTP #{response.code}: #{response.message}" unless response.code.to_i == 200
      rescue StandardError => e
        raise StandardError, "Failed to fetch collections. #{e.message}"
      end

      collections = []
      if response.is_a?(Net::HTTPSuccess)
        collections = JSON.parse(response.body)['collections']
      end

      collections
    end

    def create_collection(name = @collection_name, num_shards = 1, replication_factor = 1)
      return if collection_exists?(name)
      create_collection_url = URI.parse("#{admin_url}/collections?action=CREATE&name=#{name}&numShards=#{num_shards}&replicationFactor=#{replication_factor}")

      http = Net::HTTP.new(create_collection_url.host, create_collection_url.port)
      request = Net::HTTP::Post.new(create_collection_url.request_uri)

      begin
        response = http.request(request)
        raise StandardError, "Failed to create collection. HTTP #{response.code}: #{response.message}" unless response.code.to_i == 200
      rescue StandardError => e
        raise StandardError, "Failed to create collection. #{e.message}"
      end
    end

    def delete_collection(collection_name = @collection_name)
      return unless collection_exists?(collection_name)

      delete_collection_url = URI.parse("#{admin_url}/collections?action=DELETE&name=#{collection_name}")

      http = Net::HTTP.new(delete_collection_url.host, delete_collection_url.port)
      request = Net::HTTP::Post.new(delete_collection_url.request_uri)

      begin
        response = http.request(request)
        raise StandardError, "Failed to delete collection. HTTP #{response.code}: #{response.message}" unless response.code.to_i == 200
      rescue StandardError => e
        raise StandardError, "Failed to delete collection. #{e.message}"
      end

    end

    def collection_exists?(collection_name)
      fetch_all_collections.include?(collection_name.to_s)
    end

    def list_aliases
      aliases_url = URI.parse("#{admin_url}/collections?action=LISTALIASES")
      http = Net::HTTP.new(aliases_url.host, aliases_url.port)
      request = Net::HTTP::Get.new(aliases_url.request_uri)

      begin
        response = http.request(request)
        raise StandardError, "Failed to fetch aliases. HTTP #{response.code}: #{response.message}" unless response.code.to_i == 200
      rescue StandardError => e
        raise StandardError, "Failed to fetch aliases. #{e.message}"
      end

      JSON.parse(response.body).fetch('aliases', {})
    end

    def alias_exists?(alias_name)
      list_aliases.key?(alias_name.to_s)
    end

    def resolve_alias(alias_name)
      list_aliases[alias_name.to_s]
    end

    def create_alias(alias_name, collection_name)
      alias_url = URI.parse("#{admin_url}/collections?action=CREATEALIAS&name=#{alias_name}&collections=#{collection_name}")
      http = Net::HTTP.new(alias_url.host, alias_url.port)
      request = Net::HTTP::Post.new(alias_url.request_uri)

      begin
        response = http.request(request)
        raise StandardError, "Failed to create alias. HTTP #{response.code}: #{response.message}" unless response.code.to_i == 200
      rescue StandardError => e
        raise StandardError, "Failed to create alias. #{e.message}"
      end
    end

    def delete_alias(alias_name)
      return unless alias_exists?(alias_name)

      alias_url = URI.parse("#{admin_url}/collections?action=DELETEALIAS&name=#{alias_name}")
      http = Net::HTTP.new(alias_url.host, alias_url.port)
      request = Net::HTTP::Post.new(alias_url.request_uri)

      begin
        response = http.request(request)
        raise StandardError, "Failed to delete alias. HTTP #{response.code}: #{response.message}" unless response.code.to_i == 200
      rescue StandardError => e
        raise StandardError, "Failed to delete alias. #{e.message}"
      end
    end
  end
end

