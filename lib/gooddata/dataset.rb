require 'iconv'

##
# Module containing classes that counter-part GoodData server-side meta-data
# elements, including the server-side data model.
#
module Gooddata::Dataset
  FIELD_PK = 'id'
  FK_SUFFIX = '_id'
  FACT_PREFIX = 'f_'
  ATTRIBUTE_FOLDER_PREFIX = 'dim'
  FACT_FOLDER_PREFIX = 'ffld'

  class << self
    def to_id(str)
      Iconv.iconv('ascii//ignore//translit', 'utf-8', str) \
              .to_s.gsub(/[^\w\d_]/, '').gsub(/^[\d_]*/, '').downcase
    end
  end

  class MdObject
    attr_accessor :name, :title

    ##
    # Generates an identifier from the object name by transliterating
    # non-Latin character and then dropping non-alphanumerical characters.
    #
    def identifier
      @identifier ||= "#{self.type_prefix}.#{Gooddata::Dataset::to_id(name)}"
    end
  end

  ##
  # Server-side representation of a local data set; includes connection point,
  # attributes and labels, facts, folders and corresponding pieces of physical
  # model abstractions.
  #
  class Dataset < MdObject
    def initialize(model, title = nil)
      @title = title || model['title'] || raise("Dataset name not specified")
      @name  = @title
      labels = []
      model['columns'].each do |c|
        add_attribute Attribute.new(c, self) if c['type'] == 'ATTRIBUTE'
        add_fact Fact.new(c, self) if c['type'] == 'FACT'
        @connection_point = RecordsOf.new(c, self) if c['type'] == 'CONNECTION_POINT'
        labels.push c if c['type'] == 'LABEL'
      end
      @connection_point = RecordsOf.new(nil, self) unless @connection_point
    end

    def type_prefix ; 'dataset' ; end

    def attributes; @attributes ||= {} ; end
    def facts; @facts ||= {} ; end
    def folders; @folders ||= {}; end

    ##
    # Underlying fact table name
    #
    def table
      @table ||= FACT_PREFIX + Gooddata::Dataset::to_id(name)
    end

    ##
    # Generates MAQL DDL script to drop this data set and included pieces
    #
    def to_maql_drop
      maql = ""
      [ attributes, facts ].each do |obj|
        maql += obj.to_maql_drop
      end
      maql += "DROP {#{self.identifier}};\n"
    end

    ##
    # Generates MAQL DDL script to create this data set and included pieces
    #
    def to_maql_create
      maql = "CREATE DATASET {#{self.identifier}} VISUAL (TITLE \"#{self.title}\");\n"
      [ attributes, facts, { 1 => @connection_point } ].each do |objects|
        objects.values.each do |obj|
          maql += obj.to_maql_create
          maql += "ALTER DATASET {#{self.identifier}} ADD {#{obj.identifier}};\n"
        end
      end
      folders_maql = ''
      folders.keys.each { |folder| folders_maql += folder.to_maql_create }
      folders_maql + maql + "SYNCHRONIZE {#{identifier}}"
    end

    private

    def add_attribute(attribute)
      add_to_hash(self.attributes, attribute)
      folders[AttributeFolder.new(attribute.folder)] = 1 if attribute.folder
    end

    def add_fact(fact)
      add_to_hash(self.facts, fact)
      folders[FactFolder.new(fact.folder)] = 1 if fact.folder
    end

    def add_to_hash(hash, obj); hash[obj.identifier] = obj; end
  end

  ##
  # This is a base class for server-side LDM elements such as attributes, labels and
  # facts
  #
  class DatasetColumn < MdObject
    attr_accessor :folder

    def initialize(hash, dataset)
      @name    = hash['name'] || raise("Data set fields must have their names defined")
      @title   = hash['title'] || hash['name']
      @folder  = hash['folder']
      @dataset = dataset
    end

    def to_maql_drop
      "DROP {#{self.identifier}};\n"
    end

    private

    def visual
      visual = "TITLE \"#{title_esc}\""
      visual += ", FOLDER {#{folder_prefix}.#{Gooddata::Dataset::to_id(folder)}}" if folder
      visual
    end

    def title_esc
      title.gsub(/"/, "\\\"")
    end
  end

  ##
  # GoodData attribute abstraction
  #
  class Attribute < DatasetColumn
    def type_prefix ; 'attr' ; end
    def folder_prefix; ATTRIBUTE_FOLDER_PREFIX; end

    def labels
      @labels ||= []
    end

    def table
      @table ||= "d_" + Gooddata::Dataset::to_id(@dataset.name) + "_" + Gooddata::Dataset::to_id(name)
    end

    def to_maql_create
      "CREATE ATTRIBUTE {#{identifier}} VISUAL (#{visual})" \
             + " AS KEYS {#{table}.#{Gooddata::Dataset::FIELD_PK}} FULLSET;\n"
    end
  end

  ##
  # A GoodData attribute that represents a data set's connection point or a data set
  # without a connection point
  #
  class RecordsOf < Attribute
    def initialize(column, dataset)
      if column then
        super
      else
        @name = 'id'
        @title = "Records of #{dataset.name}"
        @folder = nil
        @dataset = dataset
      end
    end

    def table
      @table ||= "f_" + Gooddata::Dataset::to_id(@dataset.name)
    end

    def to_maql_create
      maql = super
      @dataset.attributes.values.each do |c|
        maql += "ALTER ATTRIBUTE {#{c.identifier}} ADD KEYS " \
              + "{#{table}.#{Gooddata::Dataset::to_id(c.name)}#{FK_SUFFIX}};\n"
      end
      maql
    end
  end

  ##
  # GoodData fact abstraction
  #
  class Fact < DatasetColumn
    def type_prefix ; 'fact' ; end
    def folder_prefix; FACT_FOLDER_PREFIX; end

    def table
      @dataset.table
    end

    def column
      @column ||= FACT_PREFIX + Gooddata::Dataset::to_id(name)
    end

    def to_maql_create
      "CREATE FACT {#{self.identifier}} VISUAL (#{visual})" \
             + " AS {#{table}.#{column}};\n"
    end
  end

  ##
  # Base class for GoodData attribute and fact folder abstractions
  #
  class Folder < MdObject
    def initialize(title)
      @title = title
      @name = title
    end

    def to_maql_create
      "CREATE FOLDER {#{type_prefix}.#{Gooddata::Dataset::to_id(name)}} TYPE #{type};\n"
    end
  end

  ##
  # GoodData attribute folder abstraction
  #
  class AttributeFolder < Folder
    def type; "ATTRIBUTE"; end
    def type_prefix; "dim"; end
  end

  ##
  # GoodData fact folder abstraction
  #
  class FactFolder < Folder
    def type; "FACT"; end
    def type_prefix; "ffld"; end
  end
end