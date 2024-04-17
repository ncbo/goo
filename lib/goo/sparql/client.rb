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
        "application/n-triples" => "ntriples",
        "text/x-nquads" => "nquads"
      }


      def status_based_sleep_time(operation)
        sleep(0.5)
        st = self.status

        if st[:exception]
          raise Exception, st[:exception]
        end

        if st[:outstanding] > 50
          raise Exception, "Too many outstanding queries. We cannot write to the backend"
        end

        if st[:outstanding] > 0
          return 2.5
        end

        if st[:running] < 4
          return 0.8
        end
        return 1.2
      end

      class DropGraph
        def initialize(g, silent: false)
          @graph = g
          @caching_options = { :graph => @graph.to_s }
          @silent = silent
        end
        def to_s
          "DROP #{@silent ? 'SILENT' : ''} GRAPH <#{@graph.to_s}>"
        end
        def options
          #Returns the caching option
          @caching_options
        end
      end

      def bnodes_filter_file(file_path,mime_type)
        mime_type = "application/rdf+xml" if mime_type.nil?
        format = MIMETYPE_RAPPER_MAP[mime_type]
        if format.nil?
          raise Exception, "mime_type #{mime_type} not supported in slicing"
        end
        dir = Dir.mktmpdir("file_nobnodes")
        dst_path = File.join(dir,"data.nt")
        dst_path_bnodes_out = File.join(dir,"data_no_bnodes.nt")
        out_format = format == "nquads" ? "nquads" : "ntriples"
        rapper_command_call = "rapper -i #{format} -o #{out_format} #{file_path} > #{dst_path}"
        stdout,stderr,status = Open3.capture3(rapper_command_call)
        if not status.success?
          raise Exception, "Rapper cannot parse #{format} file at #{file_path}: #{stderr}"
        end
        filter_command =
          "LANG=C grep -v '_:genid' #{dst_path} > #{dst_path_bnodes_out}"
        stdout,stderr,status = Open3.capture3(filter_command)
        if not status.success?
          raise Exception, "could not `#{filter_command}`: #{stderr}"
        end
        return dst_path_bnodes_out,dir
      end

      def delete_data_graph(graph)
        Goo.sparql_update_client.update(DropGraph.new(graph, silent: Goo.backend_vo?))
      end

      def append_triples_no_bnodes(graph,file_path,mime_type_in)
        bnodes_filter = nil
        dir = nil
        response = nil
        if file_path.end_with?('ttl')
          bnodes_filter = file_path
        else
          bnodes_filter, dir = bnodes_filter_file(file_path, mime_type_in)
        end
        chunk_lines = 500_000 # number of line
        file = File.foreach(bnodes_filter)
        lines = []
        file.each_entry do |line|
          lines << line
          if lines.size == chunk_lines
            response = execute_append_request graph, lines.join, mime_type_in
            lines.clear
          end
        end

        response = execute_append_request graph, lines.join, mime_type_in unless lines.empty?


        unless dir.nil?
          File.delete(bnodes_filter)
          begin
            FileUtils.rm_rf(dir)
          rescue => e
            puts "Error deleting tmp file #{dir}"
            puts e.backtrace
          end
        end
        response
      end

      def append_data_triples(graph,data,mime_type)
        f = Tempfile.open('data_triple_store')
        f.write(data)
        f.close()
        res = append_triples_no_bnodes(graph,f.path,mime_type)
        return res
      end

      def put_triples(graph,file_path,mime_type=nil)
        delete_graph(graph)
        result =  append_triples_no_bnodes(graph,file_path,mime_type)
        Goo.sparql_query_client.cache_invalidate_graph(graph)
        result
      end

      def append_triples(graph,data,mime_type=nil)
        result = append_data_triples(graph,data,mime_type)
        Goo.sparql_query_client.cache_invalidate_graph(graph)
        result
      end

      def append_triples_from_file(graph,file_path,mime_type=nil)
        if mime_type == "text/nquads" && !graph.instance_of?(Array)
          raise Exception, "Nquads need a list of graphs, #{graph} provided"
        end
        result = append_triples_no_bnodes(graph,file_path,mime_type)
        Goo.sparql_query_client.cache_invalidate_graph(graph)
        result
      end

      def delete_graph(graph)
        result = delete_data_graph(graph)
        Goo.sparql_query_client.cache_invalidate_graph(graph)
        return result
      end

      def extract_number_from(i,text)
        res = []
        while (text[i] != '<')
          res << text[i]
          i += 1
        end
        return 0 if res.length == 0
        return res.join("").to_i
      end

      def status
        resp = { running: -1, outstanding: -1, exception: nil }
        status_url = (url.to_s.split("/")[0..-2].join "/") + "/status/"
        resp_text = nil

        begin
          resp_text =  Net::HTTP.get(URI(status_url))
        rescue StandardError => e
          resp[:exception] = "Error connecting to triple store: #{e.class}: #{e.message}\n#{e.backtrace.join("\n\t")}"
          return resp
        end

        run_text = "Running queries</th><td>"
        i_run = resp_text.index(run_text) + run_text.length
        running = extract_number_from(i_run, resp_text)
        out_text = "Outstanding queries</th><td>"
        i_out = resp_text.index(out_text) + out_text.length
        outstanding = extract_number_from(i_out, resp_text)
        resp[:running] = running
        resp[:outstanding] = outstanding
        resp
      end

      def params_for_backend(graph, data_file, mime_type_in, method = :post)
        mime_type = "text/turtle"

        if mime_type_in == "text/x-nquads"
          mime_type = "text/x-nquads"
          graph = "http://data.bogus.graph/uri"
        end

        params = {method: method, url: "#{url.to_s}", headers: {"content-type" => mime_type, "mime-type" => mime_type}, timeout: nil}

        if Goo.backend_4s?
          params[:payload] = {
            graph: graph.to_s,
            data: data_file,
            'mime-type' => mime_type
          }
          #for some reason \\\\ breaks parsing
          params[:payload][:data] = params[:payload][:data].split("\n").map { |x| x.sub("\\\\","") }.join("\n")
        elsif Goo.backend_vo?
          params[:url] = "http://localhost:8890/sparql-graph-crud?graph=#{CGI.escape(graph.to_s)}"
          params[:payload] = data_file
        else
          params[:url] << "?context=#{CGI.escape("<#{graph.to_s}>")}"
          params[:payload] = data_file
        end
        params
      end

      def execute_append_request(graph, data_file, mime_type_in)
        RestClient::Request.execute(params_for_backend(graph, data_file, mime_type_in))
      end
    end
  end
end
