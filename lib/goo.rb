require "pry"
require "sparql_http"

require "ostruct"
require "set"
require "uri"
require "uuid"

require_relative "goo/search/search"
require_relative "goo/base/base"
require_relative "goo/naming/naming"
require_relative "goo/utils/utils"

module Goo

  @@_configuration = {}
  @@_models = Set.new
  @@_default_store = nil
  @@_uuid_generator = nil
  @@_support_skolem = false
  @@_validators = {}
  @@_search_conf = nil
  @@_search_connection = nil

  def self.models
    @@_models
  end

  def self.configure_sanity_check(conf)
    unless conf.has_key? :namespaces
      raise ArgumentError, "Namespaces needs to be provided."
    end
    unless conf[:namespaces].has_key? :default
      raise ArgumentError, "Default namespaces needs to be provided."
    end
    unless conf[:namespaces][:default].kind_of? Symbol and\
           conf[:namespaces].has_key? conf[:namespaces][:default]
      raise ArgumentError, "Default namespace must be a symbol pointing to other ns."
    end
  end

  def self.configure
    raise ArgumentError, "Configuration needs to receive a code block" \
      if not block_given?

    yield @@_configuration

    configure_sanity_check(@@_configuration)
    stores = @@_configuration[:stores]
    if stores
      stores.each do |store|
        SparqlRd::Repository.configuration(store)

        if store.has_key? :default and store[:default]
          @@_default_store  = SparqlRd::Repository.endpoint(store[:name])
        end
      end

      @@_default_store = SparqlRd::Repository.endpoint(stores[0][:name]) \
        if @@_default_store.nil?
    end

    if @@_configuration.include? :search_conf
      @@_search_conf = @@_configuration[:search_conf]
      @@_search_connection = RSolr.connect :url => @@_search_conf[:search_server]
    end

    @@_uuid_generator = UUID.new
    #somehow this upsets 4store
    #@@_support_skolem = Goo::Naming::Skolem.detect
    @@_support_skolem = false
  end

  def self.search_conf
    return @@_search_conf
  end

  def self.search_connection
    return @@_search_connection
  end

  def self.uuid
    return @@_uuid_generator
  end

  def self.store(name=nil)
    if name.nil?
      return @@_default_store
    end
    return SparqlRd::Repository.endpoint(name)
  end

  def self.is_skolem_supported?
    @@_support_skolem
  end

  def self.register_validator(name,obj)
    @@_validators[name] = obj
  end

  def self.validators
    @@_validators
  end

  def self.namespaces
    return @@_configuration[:namespaces]
  end

  def self.stores
    @@_configuration[:stores]
  end

  def self.first_or_empty_if_nil(x)
    return x[0] if x.length > 0
    return nil
  end

  def self.find_model_by_uri(uri)
    ms = @@_models.select { |m| m.type_uri == uri }
    return first_or_empty_if_nil(ms)
  end

  def self.find_model_by_name(name)
    ms = @@_models.select { |m| m.goo_name == name }
    return first_or_empty_if_nil(ms)
  end

  def self.find_prefix_for_uri(uri)
    @@_configuration[:namespaces].each_pair do |prefix,ns|
      return prefix if uri.start_with? ns
    end
    return nil
  end
end

require_relative "goo/validators/validators"
