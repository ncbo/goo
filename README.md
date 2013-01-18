# Goo

Graph Oriented Objects for Ruby. A RDF/SPARQL based ORM.

## Goo API Usage

[Goo](https://github.com/ncbo/goo) is a general library for Object to RDF Mapping written by Manuel Salvadores which includes functionality for basic CRUD operations.

### Defining a new object
We can look at some tests in Goo to see how to work with objects built with Goo.

For example, here is an object `Person` defined in a test: [`test_model_person.rb`](https://github.com/ncbo/goo/blob/master/test/test_model_person.rb)

In the method `test_person`, you can see how an instance of the model is created: `Person.new`

### Creating a new instance of a Goo object
Instances of Goo objects can be created as empty objects or by passing a Hash of attribute key/value pairs:

    > p = Person.new
    > p.name = "paul"
    # Alternatively, pass a Hash
    > p = Person.new(name: "paul")
    > p.name = "ted"

### Validating an object
There can be restrictions on the kind of data stored in an attribute for a Goo object. For example, `Person` contains an attribute called `contact_data`. This attribute can only be populated with an instance of the `ContactData` class or it will not be considered valid. This is defined as a [part of the object](https://github.com/ncbo/goo/blob/master/test/test_model_person.rb#L33) with this syntax:
`:contact_data , :instance_of => { :with => :contact_data }`

To test if an instance is valid, you can use the `valid?` method. For example:

    > p = Person.new
    > p.valid?
    => false

If calling `valid?` fails, the correspond errors will be available by calling the `errors` method, for example:

    > p = Person.new
    > p.valid?
    => false
    > p.errors

You can also check to see if an object exists prior to saving:

    > p = Person.new(name: "paul")
    > p.exist?
    => false
    > p.save
    > p.exist?
    => true

### Saving an object
After validating an object, you can call the `save` method to store the object's triples in the triplestore backend. If the object isn't valid then calling `save` will result in an exception.

### Retrieving an object
The simplest way to retrieve an object is using its id with the class method `find`:

`Person.find("paul")`

You can also do a lookup with the full id IRI:

`Person.find(RDF::IRI.new("http://example.org/person/paul"))`

Each object type has its own IRI prefix, so using the short form of the id will simply result it in being appended to the IRI prefix.

You can also search for objects using conditional statements for attributes:

    Person.where(:name => "paul")
    Person.where(:birth_date => DateTime.parse("2012-10-04T07:00:00.000Z"))

You can also retrieve instances for all objects of a given type:

`Person.all`

In the future, there will be syntax to handle [offsets and limits](https://github.com/ncbo/goo/issues/26).

### Updating an object
After retrieving an object, you can modify attributes and then save the object in order to update the data.

Another option is to delete the existing object and write a new one with the same id as the old.

### Deleting an object
Goo objects also contain a `delete` method that will remove all of the object's triples from the store.

## Goo Schema DSL

Goo employs a DSL for defining a basic schema for objects that controls how they get validated and serialized in the triplestore.

The DSL uses the method `attribute` to define a new property on the class. This is roughly equivalent to using the `attr_accessor` method in pure ruby. The primary difference is that `attribute` allows you to constrain and validate the values that can be set for the attribute in ways that work well with RDF.

### Basic validators
Here is a basic example of a Goo object, `Person`:

    class Person < Goo::Base::Resource
      attribute :name, :unique => true
      attribute :nicknames, :cardinality => { :max => 3 }
      attribute :birth_date, :date_time_xsd => true, :single_value => true , :not_nil => :true
    end

These are the validators used in the example:

- `:unique => true`
    - This validator does two things: 1) ensure that the value for the attribute is unique across all objects of this type in the triplestore; 2) use this attribute in constructing the id IRI for the object when serializing to the triplestore.
- `:cardinality => {:min => 1, :max => 5}`
    - This will restrict the allowed number of values. A `:min` cardinality of one or more will force a value to be entered (kind of like NOT NULL in SQL). Using `:max` will ensure that no more than `:max` values are set. You can use these together or individually.
- `:single_value => true`
    - This is a shortcut to `:cardinality => {:max => 1}`
- `:not_nil => true`
    - This is a shortcut to `:cardinality => {:min => 1}`
- `:date_time_xsd`
    - This will require that the value of this attribute be a valid Date Time XSD

### Advanced validators
Here is a more complex of the Person object, along with a related class called ContactData:

    class Person < Goo::Base::Resource
      model :PersonResource, :namespace => :metadata
      attribute :name, :namespace => :omv, :unique => true
      attribute :nicknames, :cardinality => { :max => 3 }
      attribute :birth_date, :date_time_xsd => true, :single_value => true , :not_nil => :true
      attribute :contact_data , :instance_of => { :with => :contact_data }
    end

    class ContactData < Goo::Base::Resource
      attribute :name, :unique => true
      attribute :phone
      attribute :people, :inverse_of => { :with => Person, :attribute => :contact_data }
    end

- `model` method
    - The `model` method can be used to define a name for the model that will be used in typing the object in RDF. A valid namespace can be provided for the type IRI.
- `:namespace`
    - Goo will use a default prefix for creating IRIs that correspond to attribute names. Where an alternative prefix needs to be used, a new namespace can be registered in the Goo config and referenced when defining Goo objects.
- `:instance_of => {:with => :contact_data}`
    - `:instance_of` will require that the value of the attribute be an instance (or instances) of  another Goo object defined by `:with`. The value of `:with` can be either an underscore symbol version of a class name (ContactData becomes :contact_data). It can also take the class reference directly, IE `:with => ContactData`.
- `:inverse_of => { :with => Person, :attribute => :contact_data }`
    - `:inverse_of` allows for a reverse lookup between related objects without the need to store actual RDF on both objects in the triplestore. In this example, all of the RDF triples relating Person and ContactData exist with subjects for the Person object. Calling ContactData#people will return a list of all the Person instances associated with this particular instance of ContactData.

