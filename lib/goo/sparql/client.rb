require 'sparql/client'
require 'net/http'
require 'open3'

RSPARQL = SPARQL
module Goo
  module SPARQL
    class Client < RSPARQL::Client

      MIMETYPE_RAPPER_MAP = {
        "application/rdf+xml" => "rdfxml",
        "application/x-turtle" => "turtle",
        "application/n-triples" => "ntriples"
      }

      def slice_file(file_path,mime_type)
        format = MIMETYPE_RAPPER_MAP[mime_type]
        if format.nil?
          raise Exception, "mime_type #{mime_type} not supported in slicing"
        end
        dir = Dir.mktmpdir("file_slice")
        dst_path = File.join(dir,"data.nt")
        dst_path_bnodes_out = File.join(dir,"data_no_bnodes.nt")
        rapper_command_call = "rapper -i #{format} -o ntriples #{file_path} > #{dst_path}" 
        stdout,stderr,status = Open3.capture3(rapper_command_call)
        if not status.success?
          raise Exception, "Rapper cannot parse #{format} file at #{file_path}: #{stderr}"
        end
        filter_command = "grep -v '_:genid' #{dst_path} > #{dst_path_bnodes_out}"
        stdout,stderr,status = Open3.capture3(filter_command)
        if not status.success?
          raise Exception, "could not `#{filter_command}`: #{stderr}"
        end
        split_command = "split -l 5000 #{dst_path_bnodes_out} #{dir}/slice"
        stdout,stderr,status = Open3.capture3(split_command)
        if not status.success?
          raise Exception, "could not split `#{split_command}`: #{stderr}"
        end
        slices = []
        Dir.foreach(dir) do |item|
          slices << File.join(dir,item) if item.start_with?("slice")
        end
        return slices
      end

      def delete_data_slices(graph)
        if graph.is_a?(String)
          graph = RDF::URI.new(graph)
        end
        qepr = Goo.sparql_query_client
        query_options = { :rules => :NONE }
        select = qepr.select(:p).distinct(true).from([graph])
        select.where( [:s, :p, :o] )
        select.options[:query_options] = query_options
        select.each_solution do |sol|
          p = sol[:p]
          begin
            more_triples = false
            select_p = qepr.select(:s,:o).distinct(true).from([graph])
            select_p.where( [:s, p, :o] )
            select_p.limit(1000)
            select_p.options[:query_options] = query_options
            graph_delete = RDF::Graph.new
            select_p.each_solution do |t|
              more_triples = true
              graph_delete << [t[:s],p,t[:o]]
            end
            if more_triples
              Goo.sparql_update_client.delete_data(graph_delete, graph: graph)
              sleep(0.75)
            end
          end while(more_triples)
        end
      end

      def append_triples_slice(graph,file_path,mime_type_in)
        slices = slice_file(file_path,mime_type_in)
        mime_type = "application/x-turtle"
        response = nil
        slices.each do |slice_path|
          params = {
            method: :post,
            url: "#{url.to_s}",
            payload: {
             graph: graph.to_s,
             data: File.read(slice_path),
             "mime-type" => mime_type
            },
            headers: {"mime-type" => mime_type},
            timeout: -1
          }
          response = RestClient::Request.execute(params)
          sleep(2.5)
        end
        return response
       
      end

      def append_data_triples_slice(graph,data,mime_type)
        f = Tempfile.open('data_triple_store')
        f.write(data)
        f.close()
        return append_triples_slice(graph,f.path,mime_type)
      end

      def put_triples(graph,file_path,mime_type=nil)
        if Goo.write_in_chunks?
          delete_graph(graph)
          return append_triples_slice(graph,file_path,mime_type)
        end

        params = {
          method: :put,
          url: "#{url.to_s}#{graph.to_s}",
          payload: File.read(file_path),
          headers: {content_type: mime_type},
          timeout: -1
        }
        return RestClient::Request.execute(params)
      end

      def append_triples(graph,data,mime_type=nil)
        if Goo.write_in_chunks?
          return append_data_triples_slice(graph,data,mime_type)
        end
        params = {
          method: :post,
          url: "#{url.to_s}",
          payload: {
            graph: graph.to_s,
            data: data,
            "mime-type" => mime_type
          },
          headers: {"mime-type" => mime_type},
          timeout: -1
        }
        return RestClient::Request.execute(params)
      end

      def append_triples_from_file(graph,file_path,mime_type=nil)
        if Goo.write_in_chunks?
          return append_triples_slice(graph,file_path,mime_type)
        end
        params = {
          method: :post,
          url: "#{url.to_s}",
          payload: {
           graph: graph.to_s,
           data: File.read(file_path),
           "mime-type" => mime_type
          },
          headers: {"mime-type" => mime_type},
          timeout: -1
        }
        return RestClient::Request.execute(params)
      end

      def delete_graph(graph)
        if Goo.write_in_chunks?
          return delete_data_slices(graph)
        end
        params = {
          method: :delete,
          url: "#{url.to_s}#{graph.to_s}",
          timeout: -1
        }
        return RestClient::Request.execute(params)
      end
    end
  end
end
