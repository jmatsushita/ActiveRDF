# Author:: Eyal Oren
# Copyright:: (c) 2005-2006 Eyal Oren
# License:: LGPL

# require 'active_rdf'

ActiveRdfLogger::log_info "Loading Sesame adapter", self


# ----- java imports and extentsions
require 'java'

# Import the jars
Dir[File.join(File.dirname(__FILE__), '..', '..', 'ext', '*.jar')].each { |jar| require jar}


StringWriter = java.io.StringWriter
JFile = java.io.File
URLClassLoader = java.net.URLClassLoader 
JURL = java.net.URL
JClass = java.lang.Class
JObject = java.lang.Object
JIOException = java.io.IOException

# sesame specific classes: 
WrapperForSesame2 = org.activerdf.wrapper.sesame2.WrapperForSesame2
QueryLanguage = org.openrdf.query.QueryLanguage
NTriplesWriter = org.openrdf.rio.ntriples.NTriplesWriter
RDFFormat = org.openrdf.rio.RDFFormat

# TODO: about this adapter
class SesameAdapter < ActiveRdfAdapter

  # This adapter supports context operations
  supports_context

  ConnectionPool.register_adapter(:sesame,self)

  # instantiates Sesame database
  # available parameters:
  # * :location => path to a file for persistent storing or :memory for in-memory (defaults to in-memory)
  # * :inferencing => true or false, if sesame2 rdfs inferencing is uses (defaults to true)
  # * :indexes => string of indexes which can be used by the persistent store, example "spoc,posc,cosp"
  #
  def initialize(params = {})
    super()
    ActiveRdfLogger::log_info "Initializing Sesame Adapter with params #{params.to_s}", self

    @reads = true
    @writes = true

    # if no directory path given, we use in-memory store
    sesame_location = nil if(params[:location] == :memory)
    sesame_location = JFile.new(params[:location]) if(params[:location])

    # if no inferencing is specified, we don't activate sesame2 rdfs inferencing
    sesame_inferencing = params[:inferencing] || false

    sesame_indices = params[:indexes] || nil

    # this will not work at the current state of jruby	
    #    # fancy JRuby code so that the user does not have to set the java CLASSPATH
    #    
    #    this_dir = File.dirname(File.expand_path(__FILE__))
    #    
    #    jar1 = JFile.new(this_dir + "/../../ext/wrapper-sesame2.jar")
    #    jar2 = JFile.new(this_dir + "/../../ext/openrdf-sesame-2.0-alpha4-onejar.jar")
    #
    #    # make an array of URL, which contains the URLs corresponding to the files
    #    uris = JURL[].new(2)
    #    uris[0] = jar1.toURL
    #    uris[1] = jar2.toURL
    #
    #    # this is our custom class loader, yay!
    #    @activerdfClassLoader = URLClassLoader.new(uris)
    #    classWrapper = JClass.forName("org.activerdf.wrapper.sesame2.WrapperForSesame2", true, @activerdfClassLoader)    
    #    @myWrapperInstance = classWrapper.new_instance 

    @myWrapperInstance = WrapperForSesame2.new

    # we have to call the java constructor with the right number of arguments
    
    ActiveRdfLogger.log_debug(self) { "Creating Sesame adapter (location: #{sesame_location}, indices: #{sesame_indices}, inferencing: #{sesame_inferencing}" }
    
    @db = @myWrapperInstance.callConstructor(sesame_location, sesame_indices, sesame_inferencing)

    @valueFactory = @db.getRepository.getSail.getValueFactory

    # define the finalizer, which will call close on the sesame triple store
    # recipie for this, is from: http://wiki.rubygarden.org/Ruby/page/show/GCAndMemoryManagement
    #    ObjectSpace.define_finalizer(self, SesameAdapter.create_finalizer(@db))       
  end

  # TODO: this does not work, but it is also not caused by jruby. 
  #  def SesameAdapter.create_finalizer(db)
  #    # we have to call close on the sesame triple store, because otherwise some of the iterators are not closed properly
  #    proc { puts "die";  db.close }
  #  end



  # returns the number of triples in the datastore (incl. possible duplicates)
  # * context => context (optional)
  def size(context = nil)
    @db.size(wrap_contexts(context))
  end

  # deletes all triples from datastore
  # * context => context (optional)
  def clear(context = nil)
    @db.clear(wrap_contexts(context))
  end

  # deletes triple(s,p,o,c) from datastore
  # symbol parameters match anything: delete(:s,:p,:o) will delete all triples
  # you can specify a context to limit deletion to that context: 
  # delete(:s,:p,:o, 'http://context') will delete all triples with that context
  # * s => subject
  # * p => predicate
  # * o => object
  # * c => context (optional)
  # Nil parameters are treated as :s, :p, :o respectively.
  def delete(s, p, o, c=nil)
    # convert variables
    params = activerdf_to_sesame(s, p, o, c, true)

    begin
      @db.remove(params[0], params[1], params[2], wrap_contexts(c))
      true
    rescue Exception => e
      raise ActiveRdfError, "Sesame delete triple failed: #{e.message}"
    end
    @db
  end

  # adds triple(s,p,o,c) to datastore
  # s,p must be resources, o can be primitive data or resource
  # * s => subject
  # * p => predicate
  # * o => object
  # * c => context (optional)
  def add(s,p,o,c=nil)
    # TODO: handle context, especially if it is null
    # TODO: do we need to handle errors from the java side ? 

    check_input = [s,p,o]
    raise ActiveRdfError, "cannot add triple with nil or blank node subject, predicate, or object" if check_input.any? {|r| r.nil? || r.is_a?(Symbol) }

    params = activerdf_to_sesame(s, p, o, c)
    @db.add(params[0], params[1], params[2], wrap_contexts(c))
    true
  rescue Exception => e
    raise ActiveRdfError, "Sesame add triple failed: #{e.message}"
  end

  # flushing is done automatically, because we run sesame2 in autocommit mode
  def flush
    true
  end	

  # saving is done automatically, because we run sesame2 in autocommit mode
  def save
    true
  end

  # close the underlying sesame triple store. 
  # if not called there may be open iterators. 
  def close
    @db.close
    ConnectionPool.remove_data_source(self)
  end

  # returns all triples in the datastore
  def dump
    # the sesame connection has an export method, which writes all explicit statements to 
    # a to a RDFHandler, which we supply, by constructing a NTriplesWriter, which writes to StringWriter, 
    # and we kindly ask that StringWriter to make a string for us. Note, you have to use stringy.to_s, 
    # somehow stringy.toString does not work. yes yes, those wacky jruby guys ;) 
    _string = StringWriter.new
    sesameWriter = NTriplesWriter.new(_string)
    @db.export(sesameWriter)
    return _string.to_s
  end

  # loads triples from file in ntriples format
  # * file => file to load
  # * syntax => syntax of file to load. The syntax can be: n3, ntriples, rdfxml, trig, trix, turtle
  # * context => context (optional)
  def load(file, syntax="ntriples", context=nil)
    # rdf syntax type
    case syntax
    when 'n3'
      syntax_type = RDFFormat::N3      
    when 'ntriples'
      syntax_type = RDFFormat::NTRIPLES
    when 'rdfxml'
      syntax_type = RDFFormat::RDFXML
    when 'trig'
      syntax_type = RDFFormat::TRIG
    when 'trix'
      syntax_type = RDFFormat::TRIX
    when 'turtle'
      syntax_type = RDFFormat::TURTLE 
    else
      raise ActiveRdfError, "Sesame load file failed: syntax not valid."
    end

    begin
      @myWrapperInstance.load(file, "", syntax_type, wrap_contexts(context))
    rescue Exception => e
      raise ActiveRdfError, "Sesame load file failed: #{e.message}"
    end
  end

  # executes ActiveRDF query on the sesame triple store associated with this adapter
  # * query => Query object
  def query(query)

    # we want to put the results in here
    results = []

    # translate the query object into a SPARQL query string
    qs = Query2SPARQL.translate(query)

    begin
      # evaluate the query on the sesame triple store
      # TODO: if we want to get inferred statements back we have to say so, as third boolean parameter
      tuplequeryresult = @db.prepareTupleQuery(QueryLanguage::SPARQL, qs).evaluate
    rescue Exception => e
      ActiveRdfLogger.log_error(self) { "Error evaluating query (#{e.message}): #{qs}" }
      raise
    end

    # what are the variables of the query ?
    variables = tuplequeryresult.getBindingNames
    size_of_variables = variables.size

    # the following is plainly ugly. the reason is that JRuby currently does not support
    # using iterators in the ruby way: with "each". it is possible to define "each" for java.util.Iterator
    # using JavaUtilities.extend_proxy but that fails in strange ways. this is ugly but works. 

    # TODO: null handling, if a value is null...

    # if there only was one variable, then the results array should look like this: 
    # results = [ [first Value For The Variable], [second Value], ...]
    if size_of_variables == 1 then
      # the counter keeps track of the number of values, so we can insert them into the results at the right position
      counter = 0 
      while tuplequeryresult.hasNext
        solution = tuplequeryresult.next

        temparray = []
        # get the value associated with a variable in this specific solution
        temparray[0] = convertSesame2ActiveRDF(solution.getValue(variables[0]), query.resource_class)
        results[counter] = temparray
        counter = counter + 1
      end    
    else
      # if there is more then one variable the results array looks like this: 
      # results = [ [Value From First Solution For First Variable, Value From First Solution For Second Variable, ...],
      #             [Value From Second Solution For First Variable, Value From Second Solution for Second Variable, ...], ...]
      counter = 0
      while tuplequeryresult.hasNext
        solution = tuplequeryresult.next

        temparray = []
        for n in 1..size_of_variables
          value = convertSesame2ActiveRDF(solution.getValue(variables[n-1]), query.resource_class)
          temparray[n-1] = value
        end   
        results[counter] = temparray
        counter = counter + 1       
      end    
    end

    return results
  end

  private

  # check if testee is a java subclass of reference
  def jInstanceOf(testee, reference)
    # for Java::JavaClass for a <=> b the comparison operator returns: -1 if a is subclass of b, 
    # 0 if a.jclass = b.jclass, +1 in any other case.
    isSubclass = (testee <=> reference)
    if isSubclass == -1 or isSubclass == 0
      return true
    else
      return false
    end
  end

  # takes a part of a sesame statement, and converts it to a RDFS::Resource if it is a URI, 
  # or to a String if it is a Literal. The assumption currently, is that we will only get stuff out of sesame, 
  # which we put in there ourselves, and currently we only put URIs or Literals there. 
  # 
  # result_type is the class that will be used for "resource" objects.
  def convertSesame2ActiveRDF(input, result_type)
    jclassURI = Java::JavaClass.for_name("org.openrdf.model.URI")
    jclassLiteral = Java::JavaClass.for_name("org.openrdf.model.Literal")	
    jclassBNode = Java::JavaClass.for_name('org.openrdf.model.BNode')

    if jInstanceOf(input.java_class, jclassURI) 
      result_type.new(input.toString)
    elsif jInstanceOf(input.java_class, jclassLiteral)
      # The string is wrapped in quotationn marks. However, there may be a language
      # indetifier outside the quotation marks, e.g. "The label"@en
      # We try to unwrap this correctly. For now we assume that there may be
      # no quotation marks inside the string
      input.toString.gsub('"', '')
    elsif jInstanceOf(input.java_class, jclassBNode)
      RDFS::BNode.new(input.toString)
    else
      raise ActiveRdfError, "the Sesame Adapter tried to return something which is neither a URI nor a Literal, but is instead a #{input.java_class.name}"
    end	
  end

  # converts spoc input into sesame objects (RDFS::Resource into 
  # valueFactory.createURI etc.)
  def activerdf_to_sesame(s, p, o, c, use_nil = false)
    params = []

    # construct sesame parameters from s,p,o,c
    [s,p,o].each { |item|
      params << wrap(item, use_nil)
    }

    # wrap Context
    params << wrap_contexts(c) unless (c.nil?)

    params
  end

  # converts item into sesame object (RDFS::Resource into 
  # valueFactory.createURI etc.). You can opt to preserve the
  # nil values, otherwise they'll be transformed
  def wrap(item, use_nil = false)
    result = 
    if(item.respond_to?(:uri))
      if (item.uri.to_s[0..4].match(/http:/).nil?)
        @valueFactory.createLiteral(item.uri.to_s)
      else
        @valueFactory.createURI(item.uri.to_s)
      end
    else
      case item
      when Symbol
        @valueFactory.createLiteral('')
      when NilClass
        use_nil ? nil : @valueFactory.createLiteral('')
      else
        @valueFactory.createLiteral(item.to_s)
      end
    end
    return result      
  end

  def wrap_contexts(*contexts)
    contexts.compact!
    contexts.collect! do |context|
      raise ActiveRdfError, "context must be a Resource" unless(context.respond_to?(:uri))
      @valueFactory.createURI(context.uri)
    end
    contexts.to_java(org.openrdf.model.Resource)
  end
end
