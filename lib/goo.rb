require "pry"
require "sparql_http"

require "ostruct"
require "set"
require "uri"
require "uuid"

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
  
  def self.models
    @@_models
  end

  def self.configure
    raise ArgumentError, "Configuration needs to receive a code block" \
      if not block_given?

    yield @@_configuration
    unless @@_configuration.has_key? :namespaces
      raise ArgumentError, "Namespaces needs to be provided."
    end
    unless @@_configuration[:namespaces].has_key? :default
      raise ArgumentError, "Default namespaces needs to be provided."
    end
    unless @@_configuration[:namespaces][:default].kind_of? Symbol and\
           @@_configuration[:namespaces].has_key? @@_configuration[:namespaces][:default]
      raise ArgumentError, "Default namespace must be a symbol pointing to other ns."
    end
    raise ArgumentError, "Store configuration not found in configuration" \
      unless @@_configuration.has_key? :stores
    stores = @@_configuration[:stores]
    stores.each do |store|
      SparqlRd::Repository.configuration(store)
      if store.has_key? :default and store[:default]
        @@_default_store  = SparqlRd::Repository.endpoint(store[:name])
      end
    end
    @@_default_store = SparqlRd::Repository.endpoint(stores[0][:name]) \
      if @@_default_store.nil?
    @@_uuid_generator = UUID.new
    @@_support_skolem = Goo::Naming::Skolem.detect
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

  def self.find_model_by_uri(uri)
    ms = @@_models.select { |m| m.type_uri == uri }
    return ms[0] if ms.length > 0
    return nil
  end

  def self.find_prefix_for_uri(uri)
    @@_configuration[:namespaces].each_pair do |prefix,ns|
      return prefix if uri.start_with? ns
    end
    return nil
  end
end

require_relative "goo/validators/validators"
