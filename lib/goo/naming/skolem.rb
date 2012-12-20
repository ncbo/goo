
module Goo
  module Naming
    module Skolem
      def self.detect
        result = nil
        blank_triple = <<eos
INSERT DATA {
GRAPH <http://goo.org/12345/54321> {
 _:b00001 <http://goo.org/12345/54321/value> "12345 54321" . }
}
eos
        epr = Goo.store()
        epr.update(blank_triple)
        query = <<eos
SELECT ?s WHERE {
GRAPH <http://goo.org/12345/54321> {
 ?s <http://goo.org/12345/54321/value> "12345 54321" . }
}
eos
        rs = epr.query(query)
        rs.each_solution do |sol|
          result = sol.get(:s).value.start_with? "http:"
        end
        blank_triple = <<eos
CLEAR GRAPH <http://goo.org/12345/54321>
eos
        epr.update(blank_triple)

        if result.nil?
          raise ArgumentError, "Wrong SPARQL interface configuration"
        end
        return result
      end
    end
  end
end
