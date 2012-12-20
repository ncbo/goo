# Goo

Graph Oriented Objects for Ruby. A RDF/SPARQL based ORM.

## Goo API

[Goo](https://github.com/ncbo/goo) is a general library for Object to RDF Mapping written by Manuel Salvadores which includes functionality for basic CRUD operations.

#### Creating a new object
We can look at some tests in Goo to see how to work with objects built with Goo.

For example, here is an object `Person` defined in a test: [`test_model_person.rb`](https://github.com/ncbo/goo/blob/master/test/test_model_person.rb#L28-L40)

In the method `test_person`, you can see how an instance of the model is created: [`Person.new`](https://github.com/ncbo/goo/blob/master/test/test_model_person.rb#L49)

#### Validating an object

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

#### Saving an object
After validating an object, you can call the `save` method to store the object's triples in the triplestore backend. If the object isn't valid then calling `save` will result in an exception.

#### Retrieving an object
The simplest way to retrieve an object is using its id with the class method `find`:

`Person.find("paul")`

You can also do a lookup with the full id IRI:

`Person.find(RDF::IRI.new("http://example.org/person/paul"))`

Each object type has its own IRI prefix, so using the short form of the id will simply result it in being appended to the IRI prefix.

You can also search for objects using attribute conditions:

    Person.where(:name => "paul")
    Person.where(:birth_date => DateTime.parse("2012-10-04T07:00:00.000Z"))

You can also retrieve all objects:

`Person.all`

In the future, there will be syntax to handle [offsets and limits](https://github.com/ncbo/goo/issues/26).

#### Updating an object
After retrieving an object, you can modify attributes and then save the object in order to update the data.

Another option is to delete the existing object and write a new one with the same id as the old.

#### Deleting an object
Goo objects also contain a `delete` method that will remove all of the object's triples from the store.
