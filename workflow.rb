require 'rbbt/workflow'
require 'rbbt/util/misc/exceptions'

Workflow.require_workflow "Genomics"
Workflow.require_workflow "Structure"
Workflow.require_workflow "DbNSFP"


module KinMut2
  extend Workflow

  helper :predict_script do
    Rbbt.bin["predict_mutations.pl"].find(:lib)
  end

  def self.organism
    Organism.default_code("Hsa")
  end


  $entrez_index = Organism.identifiers(organism).index(:target => "Entrez Gene ID", :fields => ["UniProt/SwissProt Accession"], :persist =>  true, :order => true)
  $name_index   = Organism.identifiers(organism).index(:target => "Associated Gene Name", :fields => ["UniProt/SwissProt Accession"], :persist =>  true, :order => true)
  $ensg_index   = Organism.identifiers(organism).index(:target => "Ensembl Gene ID", :fields => ["UniProt/SwissProt Accession"], :persist =>  true, :order => true)
  $ensp_index_all = Organism.protein_identifiers(organism).index(:target => "Ensembl Protein ID", :fields => ["UniProt/SwissProt Accession"], :persist =>  true,  :order => true).tap{|i| i.namespace = organism}
  $ensp_index   = Organism.protein_identifiers(organism).index(:target => "Ensembl Protein ID", :fields => ["UniProt/SwissProt Accession"], :persist =>  true,  :order => true, :data_tsv_grep => Appris::PRINCIPAL_ISOFORMS.to_a)
  $kinase_FDA_drugs = Rbbt.data["FDA_drugs_kinases_all_available.txt"].tsv :persist => false, :header_hash => "", :fields => %w(Sponsor Indications Target), :sep2 => /\s*,\s+/

  helper :organism do
    KinMut2.organism
  end


  input :mutations, :array, "Mutations"
  task :translate => :array do |mutations|
    raise ParameterException, "No mutations provided" if mutations.nil? or mutations.empty?

    translated = []
    organism = Organism.default_code("Hsa")
    translations = TSV.setup({}, :key_field => "Protein", :fields => ["UniProt/SwissProt Accession"], :type => :single, :namespace => organism)

    uni = Organism.protein_identifiers(organism).index(:target => "UniProt/SwissProt Accession", :fields => ["Ensembl Protein ID"], :persist => true)
    name = Organism.identifiers(organism).index(:target => "UniProt/SwissProt Accession", :persist => true)
    missing = []
    TSV.traverse mutations, :into => translated do |mutation|
      mutation = mutation.first if Array === mutation
      protein, change = mutation.split(/,|\s|:/)
      next unless change =~ /^[A-Z]\d+[A-Z]$/
      translation = case protein
                    when /ENSP/
                      translations[protein] = uni[protein]
                    else
                      translations[protein] = name[protein] || protein
                    end
      if translation.nil?
        missing << protein
        next
      end
      [translation, change] * " "
    end

    Open.write(file(:translations), translations.to_s)
    set_info :missing_translations, missing

    translated
  end

  dep :translate
  task :predict => :tsv do 
    mutations = step(:translate).load
    script = self.predict_script

    output = files_dir
    TmpFile.with_file(mutations*"\n") do |input|
      `perl '#{script}' -input '#{input}' -output '#{output}'`
    end
  
    features_tsv = {}
    arff = file('vectors.weka.arff').read
    attributes = arff.scan(/@attribute (.*) .*/).flatten
    vectors = begin
                arff.split('@data').last.split("\n")[1..-1].collect{|l| l.split ","}
              rescue
                raise ParameterException, "No valid kinase mutations" 
              end
    mutations.zip(vectors).each do |mutation,vector|
      features_tsv[mutation.sub(/\s/,' ')] = vector
    end
    TSV.setup(features_tsv, :key_field => "Mutation", :fields => attributes, :type => :list)

    Open.write(file("features"), features_tsv.to_s)

    FileUtils.cp(step(:translate).file(:translations), file(:translations))

    fields = %w(Mutation Prediction Score)
    header = "#" << fields * "\t"
    file_txt = header << "\n" << Open.read(File.join(output, "vectors.weka.predictions"))
    tsv = TSV.open(file_txt)
    index = TSV.index(file(:translations), :target => "Protein")
    tsv = tsv.add_field "Fixed mutation" do |mutation,values|
      uni, change = mutation.split(" ")
      orig = index[uni]
      [orig, change]  * ":"
    end
    
    tsv = tsv.reorder("Fixed mutation", ["Prediction", "Score"])
    tsv.key_field = "Mutated Isoform"
    Open.write(file(:fixed), tsv.to_s)

    file_txt
  end

  dep :predict
  task :predict_fix => :tsv do
    TSV.get_stream step(:predict).file(:fixed)
  end

  dep :predict
  task :predict_ensp => :tsv do
    prot2ensp = $ensp_index
    tsv = step(:predict).file(:fixed).tsv
    fields = tsv.fields
    tsv.key_field = "Original Mutated Isoform"
    tsv.add_field "Mutated Isoform" do |mi,values|
      prot, change = mi.split(":")
      ensp = prot2ensp[prot]
      [ensp, change]*":"
    end
    tsv = tsv.reorder "Mutated Isoform"
    tsv
  end

  dep :predict_ensp
  task :predict_all => :tsv do
    stream = TSV.get_stream step(:predict_ensp)
    s1, s2 = Misc.tee_stream stream
    smutations = CMD.cmd('cut -f 1', :in => s2, :pipe => true)
    smutations1, smutations = Misc.tee_stream smutations
    threads = []
    threads << Thread.new{Open.write(file('interfaces'), TSV.get_stream(Structure.job(:mi_interfaces, clean_name, :mutated_isoforms => smutations1).run(true)))}
    smutations2, smutations = Misc.tee_stream smutations
    threads << Thread.new{Open.write(file('dbNSFP'), TSV.get_stream(DbNSFP.job(:annotate, clean_name, :mutations => smutations2).run(true)))}

    databases = Structure::ANNOTATORS.keys - ['variants']

    databases.each do |database|
      smutations3, smutations = Misc.tee_stream smutations
      threads << Thread.new{Open.write(file(database), TSV.get_stream(Structure.job(:annotate_mi, clean_name + ': ' + database, :database => database, :mutated_isoforms => smutations3).run(true)))}
    end

    databases.each do |database|
      smutations3, smutations = Misc.tee_stream smutations
      threads << Thread.new{Open.write(file(database + '_neighbours'), TSV.get_stream(Structure.job(:annotate_mi_neighbours, clean_name + ': ' + database, :database => database, :mutated_isoforms => smutations3).run(true)))}
    end
    Misc.consume_stream smutations, true
    threads.each do |t| t.join end

    s1
  end

  export_asynchronous :predict, :predict_fix, :predict_all

end
