module RDF
  class BNode < SparqlRd::Resultset::BNode
  end
  class IRI < SparqlRd::Resultset::IRI
  end
  class Literal < SparqlRd::Resultset::Literal
  end
  def self.TYPE_FRAGMENT
    "type"
  end

  def self.NS
    "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
  end

  def self.PREFIX
    "rdf"
  end

  def self.TYPE_IRI
    "%s%s" % [self.NS,self.TYPE_FRAGMENT]
  end

  def self.TYPE_QNAME
    "%s:%s" % [self.PREFIX,self.TYPE_FRAGMENT]
  end

  @@TYPE_VARIATIONS = [ self.TYPE_FRAGMENT, self.TYPE_QNAME, self.TYPE_IRI ]
  def self.rdf_type?(k)
    (@@TYPE_VARIATIONS.index(k) != nil)
  end
end
