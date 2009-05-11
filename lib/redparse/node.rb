=begin           
    redparse - a ruby parser written in ruby
    Copyright (C) 2008  Caleb Clausen


    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU Lesser General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Lesser General Public License for more details.

    You should have received a copy of the GNU Lesser General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
=end

begin
  require 'rubygems'
rescue LoadError=>e
  raise unless /rubygems/===e.message
  #hope we don't need it
end
require 'tempfile'
require 'pp'
require "rubylexer"
require "reg"
require "regxform"





class RedParse
#  module Nodes
    #import token classes from rubylexer
    RubyLexer::constants.each{|k| 
      t=RubyLexer::const_get(k)
      self::const_set k,t if Module===t and RubyLexer::Token>=t
    }

    module FlattenedIvars
      def flattened_ivars
        result=[]
        instance_variables.sort.each{|iv| 
          if iv!="@data"
            result.push iv, instance_variable_get(iv)
          end
        }
        return result
      end

      def flattened_ivars_equal?(other)
        self.class == other.class and
          flattened_ivars == other.flattened_ivars
      end
    end

    module Stackable
      module Meta
        #declare name to be part of the identity of current class
        #variations are the allowed values for name in this class
        #keep variations simple: booleans, integers, symbols and strings only
        def identity_param name, *variations
          name=name.to_s
          list=
          if (variations-[true,false,nil]).empty?
            #const_get("BOOLEAN_IDENTITY_PARAMS") rescue const_set("BOOLEAN_IDENTITY_PARAMS",{})
              self.boolean_identity_params
          else
            #const_get("IDENTITY_PARAMS") rescue const_set("IDENTITY_PARAMS",{})
              self.identity_params
          end
          list[name]=variations
          return #old way to generate examplars below
=begin
          old_exemplars=self.exemplars||=[allocate]
          exemplars=[]
          variations.each{|var| old_exemplars.each{|exm| 
            exemplars<< res=exm.dup

            #res.send name+"=", var
            #res.send :define_method, name do var end
            Symbol|String|Integer|true|false|nil===var or fail #so inspect works as a quoting 
            eval "def res.#{name}; #{var.inspect} end"
          }}
          old_exemplars.replace exemplars
=end
        end
        def enumerate_exemplars
          @exemplars||= build_exemplars
        end
        def build_exemplars
          exemplars=[[self]]

          (boolean_identity_params.merge identity_params).each{|name,variations|
            todo=[]
            variations=variations.dup
            variations.each{|var|
              exemplars.each{|exm|
                res=exm.dup

                #res.send name+"=", var
                #res.send :define_method, name do var end
                Symbol|String|Integer|true|false|nil===var or fail #so inspect works as a quoting
                #eval "def res.#{name}; #{var.inspect} end"
                res.push name, var

                todo<<res #unless exemplars.include? res
              }
            }
            exemplars=todo
          }
          #by now, may be some exemplars with identical identities...
          #those duplicate identities should be culled
#          identities_seen={}
#          exemplars.delete_if{|ex|
#            idn=ex.identity_name
#            chuck_it=identities_seen[idn]
#            identities_seen[idn]=true
#            chuck_it
#          }

          return exemplars
        end
        attr_writer :boolean_identity_params, :identity_params
        def identity_params
          return @identity_params if defined?(@identity_params) and @identity_params
          @identity_params=
          if superclass.respond_to? :identity_params
            superclass.identity_params.dup
          else
            {}
          end
        end
        def boolean_identity_params
          return @boolean_identity_params if defined?(@boolean_identity_params) and @boolean_identity_params
          @boolean_identity_params=
          if superclass.respond_to? :boolean_identity_params
            superclass.boolean_identity_params.dup
          else
            {}
          end
        end
      end #of Meta

      def identity_name
        k=self.class
        list=[k.name]
        list.concat k.boolean_identity_params.map{|(bip,)| bip if send(bip) }.compact
        list.concat k.identity_params.map{|(ip,variations)|
          val=send(ip)
          variations.include? val or fail "identity_param #{k}##{ip} unexpected value #{val.inspect}"
          [ip,val] 
        }.flatten
        result=list.join("_")
        return result
      end
    end

    class Token
      include Stackable
      extend Stackable::Meta

      def image; "#{inspect}" end
 
      def to_parsetree(*options) #this shouldn't be needed anymore
        o={}
        [:newlines,:quirks,:ruby187].each{|opt| 
          o[opt]=true if options.include? opt
        }

        result=[parsetree(o)] 

        result=[] if result==[[]]

        return result
      end
      def lvalue; nil end
      def data; [self] end
      def unary; false end
      def rescue_parsetree(o); parsetree(o) end
      def begin_parsetree(o); parsetree(o) end

      attr :line
      alias endline line

      attr_writer :startline
      def startline
        @startline||=endline
      end
    end

    class KeywordToken
      def not_real!
        @not_real=true
      end
 
      def not_real?
        @not_real if defined? @not_real
      end

      identity_param :ident, *%w<+@ -@ unary& unary* ! ~ not defined?>+ #should be unary ops
                               %w<end ( ) { } [ ] alias undef in>+
                               %w<? : ; !~ lhs, rhs, rescue3>+ #these should be ops
                               %w{*= **= <<= >>= &&= ||= |= &= ^= /= %= -= += = => ... .. . ::}+ #shouldn't be here, grrr
                               RubyLexer::FUNCLIKE_KEYWORDLIST+
                               RubyLexer::VARLIKE_KEYWORDLIST+
                               RubyLexer::INNERBOUNDINGWORDLIST+
                               RubyLexer::BINOPWORDLIST+
                               RubyLexer::BEGINWORDLIST
      #identity_param :unary, true,false,nil
      
      #identity_param :tag, :lhs,:rhs,:param,:call,:array,:block,:nested,nil
      identity_param :callsite?, nil, true, false
      identity_param :not_real?, nil, true, false
      identity_param :infix, nil, true
      alias image ident


      warn "KeywordToken#as/infix should be in rubylexer"
      alias old_as as
      def as
        if tag and ident[/^[,*&]$/]
          tag.to_s+ident
        else old_as
        end
      end

      def infix
        @infix if defined? @infix
      end unless instance_methods.include? "infix"
    end

    class OperatorToken
      identity_param :ident, *%w[+@ -@ unary& unary* lhs* ! ~ not defined? * ** + - 
                                 < << <= <=> > >= >> =~ == ===
                                 % / & | ^ != !~ = => :: ? : , ; . .. ... 
                                 *= **= <<= >>= &&= ||= && ||
                                 &= |= ^= %= /= -= += and or
                              ]+RubyLexer::OPORBEGINWORDLIST+%w<; lhs, rhs, rescue3>
      #identity_param :unary, true,false,nil
      #identity_param :tag, :lhs,:rhs,:param,:call,:array,:block,:nested,nil

      #this should be in rubylexer
      def as
        if tag and ident[/^[,*&]$/]
          tag.to_s+ident
        end
      end
    end

    class NumberToken
      alias to_lisp to_s
      def negative; /\A-/ === ident end unless instance_methods.include? "negative"

      identity_param :negative, true,false
    end

    class MethNameToken
      alias to_lisp to_s
      def has_equals; /[a-z_0-9]=$/i===ident end unless instance_methods.include? "has_equals"

      identity_param :has_equals, true,false
    end

    class VarNameToken #none of this should be necessary now
      include FlattenedIvars
      alias image ident

      alias == flattened_ivars_equal?

      def parsetree(o)
        type=case ident[0]
         when ?$ 
           case ident[1]
           when ?1..?9; return [:nth_ref,ident[1..-1].to_i]
           when ?&,?+,?`,?'; return [:back_ref,ident[1].chr.to_sym] #`
           else :gvar
           end
         when ?@ 
           if ident[1]==?@
             :cvar
           else
             :ivar
           end
         when ?A..?Z; :const
         else 
           case lvar_type
           when :local; :lvar
           when :block; :dvar
           when :current; :dvar#_curr
           else fail
           end
         end
         return [type,ident.to_sym]
      end

      def varname2assigntype
          case ident[0]
          when ?$; :gasgn
          when ?@;
            if ident[1]!=?@;  :iasgn
            elsif in_def;     :cvasgn
            else              :cvdecl
            end
          when ?A..?Z; :cdecl
          else 
            case lvar_type
            when :local; :lasgn
            when :block; :dasgn
            when :current; :dasgn_curr
            else fail
            end
          end
      end

      def lvalue_parsetree(o)
        [varname2assigntype, ident.to_sym]
      end

      def lvalue
        return @lvalue if defined? @lvalue
        @lvalue=true
      end

      def all_current_lvars
        lvar_type==:current ? [ident] : []
      end

      attr_accessor :endline,:lvalue

      def dup
        result=super
        result.ident=@ident.dup
        return result
      end

      public :remove_instance_variable

      def unparse o=default_unparse_options; ident end
      alias lhs_unparse unparse

      def delete_extraneous_ivars!
        huh
      end

      def walk
        yield nil,nil,nil,self
      end
    end   

    class StringToken
      attr :char
    end

    class HerePlaceholderToken
      attr_accessor :node
      attr :string
    end

    class Node<Array
      include Stackable
      extend Stackable::Meta
      include FlattenedIvars

      def initialize(*data)
        replace data
      end

      def flattened_ivars
        result=super
        result.each_with_index{|x,i|
          if i&1==0 and x!="@data"
            result[i,2]=[]
          end
        }
        result
      end

      def ==(other)
        super and flattened_ivars_equal?(other)
      end

      def image; "(#{inspect})" end

      def error? x; false end

      @@data_warned=nil
      def data
        unless @@data_warned
          warn "using obsolete Node#data from #{caller.first}"
          @@data_warned=true
        end
        Array.new(self)
      end
      alias unwrap data

      attr_writer :startline
      def startline
        @startline||=endline
      end
      attr_accessor :endline
      attr_accessor :errors

      def self.[](*data)
        options=data.pop if Hash===data.last
        result=allocate
        result.instance_eval{
          replace data
          options.each_pair{|name,val|
            instance_variable_set name,val
          } if options
        }
        return result
      end

      def inspect
        ivarnames=instance_variables-["@data"]
        ivars=ivarnames.map{|ivarname| 
          ":"+ivarname+"=>"+instance_variable_get(ivarname).inspect 
        }.join(', ')
        bare=super
        bare.gsub!(/\]\Z/, ", {"+ivars+"}]") unless ivarnames.empty?
        return self.class.name+bare
      end
 
      def pretty_print(q)
        ivarnames=instance_variables-["@data"]
        ivars={}
        ivarnames.each{|ivarname| 
          ivars[ivarname.to_sym]=instance_variable_get(ivarname)
        }
        q.group(1, self.class.name+'[', ']') {
          displaylist= ivars.empty? ? self : self+[ivars]
          q.seplist(displaylist) {|v|
            q.pp v
          }
#          q.text ', '
#          q.pp_hash ivars          
        }
      end

      def self.param_names(*names)
        accessors=[]
        namelist=[]
        namelist2=[]
        names.each{|name| 
          name=name.to_s
          last=name[-1]
          name.chomp! '!' and name << ?_
          namelist2 << name
          unless last==?_
            accessors << "def #{name.chomp('_')}; self[#{namelist.size}] end\n"
            accessors << "def #{name.chomp('_')}=(newval); self[#{namelist.size}]=newval end\n"
            namelist << name
          end
        }
        init="
          def initialize(#{namelist2.join(', ')})
            replace [#{namelist.size==1 ? 
                      namelist.first : 
                      namelist.join(', ')
                  }]
          end
          alias init_data initialize
             "

        code= "class ::#{self}\n"+init+accessors.to_s+"\nend\n"
        if defined? DEBUGGER__ or defined? Debugger
          Tempfile.open("param_name_defs"){|f|
            f.write code
            f.flush
            load f.path
          }
        else
          eval code
        end
      end

      def lhs_unparse o; unparse(o) end

      def to_parsetree(*options)
        o={}
        [:newlines,:quirks,:ruby187].each{|opt| 
          o[opt]=true if options.include? opt
        }

        result=[parsetree(o)] 

        result=[] if result==[[]] || result==[nil]

        return result
      end

      def to_parsetree_and_warnings(*options)
        #for now, no warnings are ever output
        return to_parsetree(*options),[]
      end

      def parsetree(o)
        "wrong(#{inspect})"
      end

      def rescue_parsetree(o); parsetree(o) end
      def begin_parsetree(o); parsetree(o) end

      def parsetrees list,o
        !list.empty? and list.map{|node| node.parsetree(o)}
      end

      def negate(condition,offset=nil)
          if UnOpNode===condition and condition.op.ident[/^(!|not)$/]
            condition.val
          else
            UnOpNode.new(KeywordToken.new("not",offset),condition)
          end
      end

      #callback takes four parameters:
      #parent of node currently being walked, index and subindex within 
      #that parent, and finally the actual node being walked.
      def walk(parent=nil,index=nil,subindex=nil,&callback)
        callback[ parent,index,subindex,self ] and
        each_with_index{|datum,i|
          case datum
          when Node; datum.walk(self,i,&callback)
          when Array;
            datum.each_with_index{|x,j| 
              Node===x ? x.walk(self,i,j,&callback) : callback[self,i,j,x]
            }
          else callback[self,i,nil,datum]
          end
        }
      end

      def depthwalk(parent=nil,index=nil,subindex=nil,&callback)
        each_with_index{|datum,i|
          case datum
          when Node
            datum.depthwalk(self,i,&callback)
          when Array
            datum.each_with_index{|x,j| 
              if Node===x
                x.depthwalk(self,i,j,&callback) 
              else 
                callback[self,i,j,x]
              end
            }
          else 
            callback[self, i, nil, datum]
          end
        }
        callback[ parent,index,subindex,self ]
      end

      def add_parent_links!
        walk{|parent,i,subi,o|
          o.parent=parent if Node===o
        }
      end

      attr_accessor :parent

      def xform_tree!(xformer)
        session={}
        depthwalk{|parent,i,subi,o|
          xformer.xform!(o,session) if o
        }
        session["final"]=true
        depthwalk{|parent,i,subi,o|
          if session.has_key? o.__id__
            new= session[o.__id__]
            if Reg::Formula===new
              new=new.formula_value(session,o)
            end
            subi ? parent[i][subi]=new : parent[i]=new
          end
        }
        if session.has_key? self.__id__
          new= session[self.__id__]
          if Reg::Formula===new
            new=new.formula_value(session,self)
          end
          return new
        else
          return self
        end
      end

      def linerange
        min=9999999999999999999999999999999999999999999999999999
        max=0
        walk{|parent,i,subi,node|
          if node.respond_to? :endline and line=node.endline
            min=[min,line].min
            max=[max,line].max
          end
        }
        return min..max
      end

      def fixup_multiple_assignments! #dead code
       result=self
       walk{|parent,i,subi,node|
        if CommaOpNode===node
          #there should be an assignnode within this node... find it
          j=nil
          list=Array.new(node)
          assignnode=nil
          list.each_with_index{|assignnode,jj|
            AssignNode===assignnode and break(j=jj)
          }
          fail "CommaOpNode without any assignment in final parse tree" unless j

          #re-hang the current node with = at the top
          lhs=list[0...j]<<list[j].left
          rhs=list[j+1..-1].unshift list[j].right
          if lhs.size==1 and MultiAssign===lhs.first
            lhs=lhs.first
          else
            lhs=MultiAssign.new(lhs)
          end
          node=AssignNode.new(lhs, assignnode.op, rhs)

          #graft the new node back onto the old tree
          if parent
            if subi
              parent[i][subi]=node
            else
              parent[i]=node
            end
          else #replacement at top level
            result=node
          end

          #re-scan newly made node, since we tell caller not to scan our children
          node.fixup_multiple_assignments!

          false #skip (your old view of) my children, please
        else
          true
        end
       }
 
       return result

      end

      def prohibit_fixup x
        case x
        when UnaryStarNode; true
#        when ParenedNode; x.size>1
        when CallSiteNode; x.params and !x.real_parens
        else false
        end
      end

      def fixup_rescue_assignments! #dead code
        result=self
        walk{|parent,i,subi,node|
          #if a rescue op with a single assignment on the lhs
          if RescueOpNode===node and assign=node.first and #ick
               AssignNode===assign and assign.op.ident=="=" and 
               !(assign.multi? or 
                 prohibit_fixup assign.right)


            #re-hang the node with = at the top instead of rescue
            node=AssignNode.new(assign.left, assign.op,
              RescueOpNode.new(assign.right,nil,node[1][0].action)
            )
            
            #graft the new node back onto the old tree
            if parent
              if subi
                parent[i][subi]=node
              else
                parent[i]=node
              end
            else #replacement at top level
              result=node
            end

            #re-scan newly made node, since we tell caller not to scan our children
            node.fixup_rescue_assignments!

            false #skip (your old view of) my children, please
          else
            true
          end
        }
        return result
      end
 
      def lvars_defined_in
        result=[]
        walk {|parent,i,subi,node|
          case node
          when MethodNode,ClassNode,ModuleNode,MetaClassNode; false
          when CallSiteNode
            Node===node.receiver and
              result.concat node.receiver.lvars_defined_in 
            node.args.each{|arg| 
              result.concat arg.lvars_defined_in if Node===arg
            } if node.args
            false
          when AssignNode
            lvalue=node.left
            lvalue.respond_to? :all_current_lvars and
              result.concat lvalue.all_current_lvars 
            true
          when ForNode
            lvalue=node.for
            lvalue.respond_to? :all_current_lvars and
              result.concat lvalue.all_current_lvars 
            true
          when RescueOpNode,BeginNode
              rescues=node[1]
              rescues.each{|resc|
                name=resc.varname
                name and result.push name.ident
              }
            true
          else true
          end
        }

        result.uniq!
        return result
      end

      def unary; false end
      def lvalue; nil end

      def deep_copy transform={},&override
        handler=proc{|child|
          if transform.has_key? child.__id__ 
            transform[child.__id__]
          else
            case child
            when Node: 
                override&&override[child] or 
                  child.deep_copy(transform,&override)
            when Array: 
                child.map(&handler)
            when Integer,Symbol,Float,nil,false,true,Module:
                child
            else 
                child.dup
            end
          end
        }

        newdata=map(&handler)

        h={}
        result_module=nil
        instance_variables.each{|iv| 
          unless iv=="@data"
            val=instance_variable_get(iv)
            h[iv]=handler[val]
            result_module=val if iv=="@module" #hacky
          end
        }
        result= self.class[*newdata << h]
        result.extend result_module if result_module
        return result
      end

      def delete_extraneous_ivars!
        walk{|parent,i,subi,node|
          case node
          when Node
            node.remove_instance_variable :@offset rescue nil
            node.remove_instance_variable :@loopword_offset rescue nil
            node.remove_instance_variable :@endline rescue nil
            node.remove_instance_variable :@lvalue rescue nil
            if node.respond_to? :lvalue 
              node.lvalue or
                node.remove_instance_variable :@lvalue rescue nil 
            end
          when Token
            print "#{node.inspect} in "; pp parent
            fail "no tokens should be present in final parse tree (maybe except VarNameToken, ick)"
          end
          true
        }
        return self
      end

      public :remove_instance_variable

      #convert to a Reg::Array expression. subnodes are also converted.
      #if any matchers are present in the tree, they will be included
      #directly into the enclosing Node's matcher.
      #this can be a nice way to turn a (possibly deeply nested) node
      #tree into a matcher.
      #note: anything stored in instance variables is ignored in the 
      #matcher.
      def +@
        node2matcher=proc{|n|
          case n
          when Node: +n
          when Array: +[*n.map(&node2matcher)]
          else n
          end
        }
        return +[*map(&node2matcher)] & self.class
      end

    private

      #turn a list (array) of arrays into a linked list, in which each array
      #has a reference to the next in turn as its last element.
      def linked_list(arrays)
        0.upto(arrays.size-2){|i| arrays[i]<<arrays[i+1] }
        return arrays.first
      end

      def param_list_walk(param_list)
        param_list or return
        limit=param_list.size
        i=0
        normals=[]
        lownormal=nil
        handle_normals=proc{
          yield '',normals,lownormal..i-1 if lownormal
          lownormal=nil
          normals.slice! 0..-1
        }
        while i<limit
          case param=param_list[i]
          when ArrowOpNode
            handle_normals[]
            low=i
            i+=1 while ArrowOpNode===param_list[i]
            high=i-1
            yield '=>',param_list[low..high],low..high
          when UnaryStarNode
            handle_normals[]
            yield '*',param,i
          when UnOpNode&-{:op=>"&@"}
            handle_normals[]
            yield '&',param,i
          else
            lownormal=i unless lownormal
            normals << param
          end
          i+=1
        end
        handle_normals[]
      end

      def param_list_parse(param_list,o)
        output=[]
        star=amp=nil
        param_list_walk(param_list){|type,val,i|
          case type
          when ''
            output.concat val.map{|param| param.rescue_parsetree(o)}
          when '=>'
            output.push HashLiteralNode.new(nil,val,nil).parsetree(o)
          when '*'; star=val.parsetree(o)
          when '&'; amp=val.parsetree(o)
          end
        }
        return output,star,amp
      end

      def unparse_nl(token,o,alt=';',nl="\n")

        #should really only emit newlines 
        #to bring line count up to startline, not endline.
        #but that doesn't exist yet

        linenum= Integer===token ? token : token.endline rescue o[:linenum]
        shy=linenum-o[:linenum]
        return alt if shy<=0
        o[:linenum]=linenum
        return nl*shy
      end

      def default_unparse_options
        {:linenum=>1}
      end
    end

    class ValueNode<Node
      def lvalue; nil end
      #identity_param :lvalue, nil, true
    end

    class VarNode<ValueNode
      include FlattenedIvars
      attr_accessor :endline,:lvalue,:ident
      attr_reader :lvar_type,:in_def,:offset
      alias image ident
      alias startline endline

      alias == flattened_ivars_equal?

      def initialize(tok)
        @ident=tok.ident
        @lvar_type=tok.lvar_type
        @offset=tok.offset
        @endline=tok.endline
        @in_def=tok.in_def
      end

      def parsetree(o)
        type=case ident[0]
         when ?$: 
           case ident[1]
           when ?1..?9; return [:nth_ref,ident[1..-1].to_i]
           when ?&,?+,?`,?'; return [:back_ref,ident[1].chr.to_sym] #`
           else :gvar
           end
         when ?@
           if ident[1]==?@
             :cvar
           else
             :ivar
           end
         when ?A..?Z; :const
         else 
           case lvar_type
           when :local; :lvar
           when :block; :dvar
           when :current; :dvar#_curr
           else fail
           end
         end
         return [type,ident.to_sym]
      end

      def varname2assigntype
          case ident[0]
            when ?$; :gasgn
            when ?@
              if ident[1]!=?@;  :iasgn
              elsif in_def;     :cvasgn
              else              :cvdecl
              end
            when ?A..?Z; :cdecl
            else
              case lvar_type
              when :local; :lasgn
              when :block; :dasgn
              when :current; :dasgn_curr
              else fail
              end
          end
      end

      def lvalue_parsetree(o)
        [varname2assigntype, ident.to_sym]
      end

      alias to_lisp to_s

      def lvalue
        return @lvalue if defined? @lvalue
        @lvalue=true
      end

      identity_param :lvalue, nil, true

      def all_current_lvars
        lvar_type==:current ? [ident] : []
      end


      def dup
        result=super
        result.ident=@ident.dup if @ident
        return result
      end

      public :remove_instance_variable

      def unparse o=default_unparse_options; ident end
      alias lhs_unparse unparse

#      def delete_extraneous_ivars!
#        remove_instance_variable :@lvalue
#        super
#      end

if false
      def walk #is this needed?
         yield nil,nil,nil,self
      end
end

    end

    #forward decls
    module ArrowOpNode; end
    module RangeNode; end
    module LogicalNode; end
    module WhileOpNode; end
    module UntilOpNode; end
    module IfOpNode; end
    module UnlessOpNode; end
    module OpNode; end
    module NotEqualNode; end
    module MatchNode; end
    module NotMatchNode; end

    OP2MIXIN={
      "=>"=>ArrowOpNode,
      ".."=>RangeNode,
      "..."=>RangeNode,
      "&&"=>LogicalNode,
      "||"=>LogicalNode,
      "and"=>LogicalNode,
      "or"=>LogicalNode,
      "while"=>WhileOpNode,
      "until"=>UntilOpNode,
      "if"=>IfOpNode,
      "unless"=>UnlessOpNode,
      "!="=>NotEqualNode,
      "!~"=>NotMatchNode,
      "=~"=>MatchNode,
    }

    class RawOpNode<ValueNode
      param_names(:left,:op,:right)
      def initialize(left,op,right)
        @offset=op.offset
        op=op.ident
        super(left,op,right)
        Array((OP2MIXIN[op]||OpNode)).each{|mod|
          extend(mod)        
          mod.instance_method(:initialize).bind(self).call(left,op,right)
        }
      end
      def self.[](*args)
        result=super
        @module and extend @module
        return result
      end
      def image; "(#{op})" end
      def raw_unparse o
        l=left.unparse(o)
        l[/(~| \Z)/] and maybesp=" "
        [l,op,maybesp,right.unparse(o)].to_s
      end
    end

    module OpNode
      def initialize(left,op,right)
        #@negative_of="="+$1 if /^!([=~])$/===op
        @module=OpNode
      end
      def to_lisp
        "(#{op} #{left.to_lisp} #{right.to_lisp})"
      end

      def parsetree(o)
        [:call, 
           left.rescue_parsetree(o), 
           op.to_sym, 
           [:array, right.rescue_parsetree(o)]
        ]
      end
      alias opnode_parsetree parsetree

      def unparse o=default_unparse_options
        result=l=left.unparse(o)
        result+=" " if /\A!|a-z_/i===op
        result+=op
        result+=" " if /a-z_/i===op or / \Z/===l
        result+=right.unparse(o)      
      end

#      def unparse o=default_unparse_options; raw_unparse o end
    end

    module MatchNode
      include OpNode

      def parsetree(o)
        if StringNode===left and left.char=='/'
          [:match2, left.parsetree(o), right.parsetree(o)]
        elsif StringNode===right and right.char=='/'
          [:match3, right.parsetree(o), left.parsetree(o)]
        else
          super 
        end
      end
      def op; "=~"; end
    end

    module NotEqualNode
      include OpNode

      def parsetree(o)
        result=opnode_parsetree(o)
        result[2]="=#{op[1..1]}".to_sym
        result=[:not, result]
        return result
      end
      def op; "!="; end
    end

    module NotMatchNode
      include NotEqualNode

      def parsetree(o)
        if StringNode===left and left.char=="/"
          [:not, [:match2, left.parsetree(o), right.parsetree(o)]]
        elsif StringNode===right and right.char=="/"
          [:not, [:match3, right.parsetree(o), left.parsetree(o)]]
        else
          super
        end
      end

      def op; "!~"; end
    end

    class ListOpNode<ValueNode #abstract
      def initialize(val1,op,val2)
        list=if self.class===val1
               Array.new(val1)
             else
               [val1]
             end
        if self.class===val2
          list.push( *val2 )
        elsif val2
          list.push val2
        end 
        super( *list )
      end
    end

    class CommaOpNode<ListOpNode #not to appear in final tree
      def image; '(,)' end
      def to_lisp
        "(#{map{|x| x.to_lisp}.join(" ")})"
      end
      def lvalue
        return @lvalue if defined? @lvalue
        @lvalue=true
      end
      attr_writer :lvalue
      identity_param :lvalue, nil, true
    end

    class LiteralNode<ValueNode; end
    class StringNode<ValueNode; end
    class StringCatNode < ValueNode; end
    class NopNode<ValueNode; end
    class VarLikeNode<ValueNode; end  #nil,false,true,__FILE__,__LINE__,self

    class SequenceNode<ListOpNode
      def image; '(;)' end
      def to_lisp
        "#{map{|x| x.to_lisp}.join("\n")}"
      end

      def to_lisp_with_parens
        "(#{to_lisp})"
      end

      LITFIX=LiteralNode&-{:val=>Fixnum}
      LITRANGE=RangeNode&-{:left=>LITFIX,:right=>LITFIX}
      LITSTR=StringNode&-{:size=>1,:char=>/^[^`\[{]$/}
      #LITCAT=proc{|item| item.grep(~LITSTR).empty?}
      #class<<LITCAT; alias === call; end
      LITCAT=StringCatNode& item_that.grep(~LITSTR).empty? #+[LITSTR.+]
      LITNODE=LiteralNode|NopNode|LITSTR|LITCAT|LITRANGE|(VarLikeNode&-{:name=>/^__/})
            #VarNode|  #why not this too?
      def parsetree(o)
        data=compact
        data.empty? and return
        items=Array.new(data[0...-1])
        if o[:quirks]
          items.shift while LITNODE===items.first
        else
          items.reject!{|expr| LITNODE===expr }
        end
        items.map!{|expr| expr.rescue_parsetree(o)}.push last.parsetree(o)
#        items=map{|expr| expr.parsetree(o)}
        items.reject!{|expr| []==expr }
        if o[:quirks] 
          unless BeginNode===data[0]
            header=items.first
            (items[0,1] = *header[1..-1]) if header and header.first==:block
          end
        else
          (items.size-1).downto(0){|i|
            header=items[i]
            (items[i,1] = *header[1..-1]) if header and header.first==:block
          }     
        end
        if items.size>1
          items.unshift :block
        elsif items.size==1
          items.first
        else
          items
        end
      end

      def unparse o=default_unparse_options
        map{|expr| unparse_nl(expr,o)+expr.unparse(o)}.to_s
      end
    end

    class StringCatNode < ValueNode
      def initialize(*strses)
        strs=strses.pop.unshift( *strses )
        hd=strs.shift if HereDocNode===strs.first
        strs.map!{|str| StringNode.new(str)}
        strs.unshift hd if hd
        super( *strs )
      end
      def parsetree(o)
        result=map{|str| str.parsetree(o)}
        sum=''
        type=:str
        tree=i=nil
        result.each_with_index{|tree,i| 
          sum+=tree[1]
          tree.first==:str or break(type=:dstr)
        }
        [type,sum,*tree[2..-1]+result[i+1..-1].inject([]){|cat,x|
          if x.first==:dstr
            x.shift
            x0=x[0] 
            if x0=='' and x.size==2
              x.shift
            else
              x[0]=[:str,x0]
            end
            cat+x
          else
            cat+[x]
          end
          }
        ]
      end

      def unparse o=default_unparse_options
        map{|ss| ss.unparse(o)}.join ' '      
      end
    end

#    class ArrowOpNode<ValueNode
#      param_names(:left,:arrow_,:right)
#    end
     module ArrowOpNode
       def initialize(*args) 
         @module=ArrowOpNode
       end

       def unparse(o=default_unparse_options)
         left.unparse(o)+" => "+right.unparse(o)
       end
     end

#    class RangeNode<ValueNode
    module RangeNode
#      param_names(:first,:op_,:last)
      def initialize(left,op_,right)
        @exclude_end=!!op_[2]
        @module=RangeNode
        @as_flow_control=false
#        super(left,right)
      end
      def begin; left end
      def end; right end
      def first; left end
      def last; right end
      def exclude_end?; @exclude_end end

      def parsetree(o)
        first=first().parsetree(o)
        last=last().parsetree(o)
        if :lit==first.first and :lit==last.first and
           Fixnum===first.last and Fixnum===last.last
          return [:lit, Range.new(first.last,last.last,@exclude_end)]
        end
        tag= @as_flow_control ? "flip" : "dot"
        count= @exclude_end ? ?3 : ?2
        tag << count
        [tag.to_sym, first, last]
      end

      def special_conditions!
        @as_flow_control=true
      end

      def unparse(o=default_unparse_options)
        result=left.unparse(o)+'..'
        result+='.' if exclude_end?
        result << right.unparse(o)
        return result      
      end
    end

    class UnOpNode<ValueNode
      param_names(:op,:val)
      def initialize(op,val)
        op=op.ident
        /([&*])$/===op and op=$1+"@"
        /^(?:!|not)$/===op and 
          val.respond_to? :special_conditions! and 
            val.special_conditions!
        super(op,val)
      end
   
      alias ident op

      def image; "(#{op})" end

      def lvalue
#        return nil unless op=="*@"

        return @lvalue if defined? @lvalue
        @lvalue=true
      end
      attr_writer :lvalue

      def to_lisp
        "(#{op} #{val.to_lisp})"
      end

      def parsetree(o)
        node=self
        node=node.val while UnOpNode===node and node.op=="+@"
        return node.parsetree(o) if LiteralNode&-{:val=>Integer|Float|Symbol}===node
        return node.parsetree(o) if StringNode&-{:char=>'/', :size=>1}===node

        case op
        when /^&/; [:block_arg, val.ident.to_sym]
        when "!","not"; [:not, val.rescue_parsetree(o)]
        when "defined?"; [:defined, val.parsetree(o)]
        else
          [:call, val.rescue_parsetree(o), op.to_sym]
        end
      end

      def lvalue_parsetree(o)
        parsetree(o)
      end

      def unparse o=default_unparse_options
        op=op()
        op=op.chomp "@"
        result=op
        result+=" " if /[a-z_]/i===op or /^[+-]/===op && LiteralNode===val
        result+=val.unparse(o)
      end
    end

    class UnaryStarNode<UnOpNode
      def initialize(op,val)
        op.ident="*@"
        super(op,val)
      end

      def parsetree(o)
        [:splat, val.rescue_parsetree(o)]
      end

      def all_current_lvars
        val.respond_to?(:all_current_lvars) ?
          val.all_current_lvars : []
      end
      attr_accessor :after_comma

      def lvalue_parsetree o
        val.lvalue_parsetree(o)
      end

      identity_param :lvalue, nil, true

      def unparse o=default_unparse_options
        "*"+val.unparse(o)      
      end
    end

    class DanglingStarNode<UnaryStarNode
      #param_names :op,:val
      def initialize(star)
        @offset= star.offset
        replace ['*@',VarNode.new(VarNameToken.new('',offset))]
      end
      attr :offset
      def lvars_defined_in; [] end
      def parsetree(o); [:splat] end
      alias lvalue_parsetree parsetree

      def unparse(o=nil); "* "; end
    end

    class DanglingCommaNode<DanglingStarNode
      def initialize
        
      end
      attr_accessor :offset

      def lvalue_parsetree o
        :dangle_comma
      end
      alias parsetree lvalue_parsetree

      def unparse o=default_unparse_options;  "";   end
    end

    class ConstantNode<ListOpNode
      def initialize(*args)
        args.unshift nil if args.size==2
        args.map!{|node| 
          if VarNode===node and (?A..?Z)===node.ident[0]
          then node.ident 
          else node
          end
        }
        super(*args)  
      end
      def unparse(o=default_unparse_options)
        if Node===first
          result=dup
          result[0]= first.unparse(o)#.gsub(/\s+\Z/,'')
          result.join('::')
        else join('::')
        end
      end
      alias image unparse
      def lvalue_parsetree(o)
        [:cdecl,parsetree(o)]
      end
      def parsetree(o)
        if !first
          result=[:colon3, self[1].to_sym]
          i=2
        else
          result=first.respond_to?(:parsetree) ? 
                   first.parsetree(o) :
                   [:const,first.to_sym]
          i=1
        end
        (i...size).inject(result){|r,j| 
          [:colon2, r, self[j].to_sym]
        }
      end

      def lvalue
        return @lvalue if defined? @lvalue
        @lvalue=true
      end
      attr_writer :lvalue
      identity_param :lvalue, nil, true
    end
    LookupNode=ConstantNode

    class DoubleColonNode<ValueNode       #obsolete
         #dunno about this name...     maybe ConstantNode?
      param_names :namespace, :constant
      alias left namespace
      alias right constant
      def initialize(val1,op,val2=nil)
        val1,op,val2=nil,val1,op unless val2
        val1=val1.ident if VarNode===val1 and /\A[A-Z]/===val1.ident
        val2=val2.ident if VarNode===val1 and /\A[A-Z]/===val2.ident
        replace [val1,val2]
      end

      def image; '(::)' end
 

      def parsetree(o)
        if namespace
          ns= (String===namespace) ? [:const,namespace.to_sym] : namespace.parsetree(o)
          [:colon2, ns, constant.to_sym]
        else
          [:colon3, constant.to_sym]
        end
      end
      def lvalue_parsetree(o)
        [:cdecl,parsetree(o)]
      end

      def lvalue
        return @lvalue if defined? @lvalue
        @lvalue=true
      end
      attr_writer :lvalue
    end

    class DotCallNode<ValueNode #obsolete
      param_names :receiver,:dot_,:callsite

      def image; '(.)' end

      def to_lisp
        "(#{receiver.to_lisp} #{@data.last.to_lisp[1...-1]})"
      end

      def parsetree(o)
        cs=self[1]
        cs &&= cs.parsetree(o)
        cs.shift if cs.first==:vcall or cs.first==:fcall
        [:call, @data.first.parsetree(o), *cs]
      end
      def lvalue
        return @lvalue if defined? @lvalue
        @lvalue=true
      end
      attr_writer :lvalue
    end

=begin
    class OldParenedNode<ValueNode
      param_names :body, :rescues, :else!, :ensure!
      def initialize(*args)
        @empty_ensure=@op_rescue=nil
        replace(
        if args.size==3  #()
          if (KeywordToken===args.first and args.first.ident=='(')
            [args[1]] 
          else
            expr,rescueword,backup=*args
            @op_rescue=true
            [expr,[RescueNode[[],nil,backup]],nil,nil]    
          end
        else
          body,rescues,else_,ensure_=*args[1...-1]
          if else_
            else_=else_.val or @empty_else=true
          end
          if ensure_
            ensure_=ensure_.val or @empty_ensure=true
          end
          [body,rescues,else_,ensure_]
        end
        )
      end

      alias ensure_ ensure
      alias else_ else

      attr_reader :empty_ensure, :empty_else
      attr_accessor :after_comma, :after_equals
      def op?; @op_rescue; end

      def image; '(begin)' end

      def special_conditions!
        if size==1
          node=body
          node.special_conditions! if node.respond_to? :special_conditions!
        end
      end

      def to_lisp
        huh #what about rescues, else, ensure?
        body.to_lisp
      end
 
      def parsetree(o)
        if size==1
          body.parsetree(o)
        else
          body=body()
          target=result=[]   #was: [:begin, ]

          #body,rescues,else_,ensure_=*self
          target.push target=[:ensure, ] if ensure_ or @empty_ensure

          rescues=rescues().map{|resc| resc.parsetree(o)}
          if rescues.empty? 
            else_ and
              body=SequenceNode.new(body,nil,else_)
            else_=nil
          else 
            target.push newtarget=[:rescue, ]
            else_=else_()
          end
          if body 
              needbegin=  (BeginNode===body and body.after_equals)
              body=body.parsetree(o) 
              body=[:begin, body] if needbegin and body.first!=:begin and !o[:ruby187]
              (newtarget||target).push body if body
          end
          target.push ensure_.parsetree(o) if ensure_
          target.push [:nil] if @empty_ensure
          target=newtarget if newtarget
          
          unless rescues.empty?
            target.push linked_list(rescues)
          end
          target.push else_.parsetree(o) if  else_ #and !body
          result.size==0 and result=[[:nil]]
          result=result.last #if @op_rescue
          result=[:begin,result] unless o[:ruby187]||op?||result==[:nil]#||result.first==:begin
          result
        end
      end

      def rescue_parsetree o
        result=parsetree o
        result.first==:begin and result=result.last unless o[:ruby187]
        result
      end

      def begin_parsetree(o)
        body,rescues,else_,ensure_=*self
        needbegin=(rescues&&!rescues.empty?) || ensure_ || @empty_ensure
        result=parsetree(o)
        needbegin and result=[:begin, result] unless result.first==:begin
        result
      end

      def lvalue
        return nil unless size==1 
#        case first
#        when CommaOpNode,UnaryStarNode: #do nothing
#        when ParenedNode: return first.lvalue
#        else return nil
#        end

        return @lvalue if defined? @lvalue
        @lvalue=true
      end
      attr_writer :lvalue

      def unparse(o=default_unparse_options)
        if size==1
          "("+(body&&body.unparse(o))+")"
        else
          result="begin "
          body&&result+= body.unparse(o)
          result+=unparse_nl(rescues.first,o)
          rescues.each{|resc| result+=resc.unparse(o) }
          result+=unparse_nl(ensure_,o)+"ensure "+ensure_.unparse(o) if ensure_
          result+=unparse_nl(else_,o)+"else "+else_.unparse(o) if else_
          result+=";end"
        end
      end
    end
=end

    class ParenedNode<ValueNode
      param_names :body #, :rescues, :else!, :ensure!
      def initialize(lparen,body,rparen)
        self[0]=body
      end

      attr_accessor :after_comma, :after_equals

      def image; "(#{body.image})" end

      def special_conditions!
          node=body
          node.special_conditions! if node.respond_to? :special_conditions!
      end

      def to_lisp
        huh #what about rescues, else, ensure?
        body.to_lisp
      end

      def op?; false end
 
      def parsetree(o)
          body.parsetree(o)
      end

      def rescue_parsetree o
        body.rescue_parsetree o
#        result.first==:begin and result=result.last unless o[:ruby187]
#        result
      end

      alias begin_parsetree parsetree

      def lvalue
        return @lvalue if defined? @lvalue
        @lvalue=true
      end
      attr_writer :lvalue

      identity_param :lvalue, nil, true

      def unparse(o=default_unparse_options)
          "("+(body&&body.unparse(o))+")"
      end
    end

    module HasRescue
      def parsetree_and_rescues(o)
          body=body()
          target=result=[]   #was: [:begin, ]

          #body,rescues,else_,ensure_=*self
          target.push target=[:ensure, ] if ensure_ or @empty_ensure

          rescues=rescues().map{|resc| resc.parsetree(o)}
          if rescues.empty?
            else_ and
              body=SequenceNode.new(body,nil,else_)
            else_=nil
          else
            target.push newtarget=[:rescue, ]
            else_=else_()
          end
          if body
#              needbegin=  (BeginNode===body and body.after_equals)
              body=body.parsetree(o)
#              body=[:begin, body] if needbegin and body.first!=:begin and !o[:ruby187]
              (newtarget||target).push body if body
          end
          target.push ensure_.parsetree(o) if ensure_
          target.push [:nil] if @empty_ensure
          target=newtarget if newtarget

          unless rescues.empty?
            target.push linked_list(rescues)
          end
          target.push else_.parsetree(o) if  else_ #and !body
          result.size==0 and result=[[:nil]]
          result=result.last #if @op_rescue
          result
      end

      def unparse_and_rescues(o)
          result=" "
          result+= body.unparse(o) if body
          result+=unparse_nl(rescues.first,o)
          rescues.each{|resc| result+=resc.unparse(o) }
          result+=unparse_nl(else_,o)+"else "+else_.unparse(o) if else_
          result+=";else" if @empty_else
          result+=unparse_nl(ensure_,o)+"ensure "+ensure_.unparse(o) if ensure_
          result+=";ensure" if @empty_ensure 
          return result
       end

    end

    class BeginNode<ValueNode
      include HasRescue
      param_names :body, :rescues, :else!, :ensure!
      def initialize(*args)
        @empty_ensure=@empty_else=@op_rescue=nil
          body,rescues,else_,ensure_=*args[1...-1]
          if else_
            else_=else_.val or @empty_else=true
          end
          if ensure_
            ensure_=ensure_.val or @empty_ensure=true
          end
          replace [body,rescues,else_,ensure_]
      end

      def op?; false end

      alias ensure_ ensure
      alias else_ else

      attr_reader :empty_ensure, :empty_else
      attr_accessor :after_comma, :after_equals

      identity_param :after_equals, nil,  true

      def image; '(begin)' end

      def special_conditions!; nil end

      def non_empty
        body.size+rescues.size > 0 or !!ensures
      end

      identity_param :non_empty, false, true

      def to_lisp
        huh #what about rescues, else, ensure?
        body.to_lisp
      end
 
      def parsetree(o)
        result=parsetree_and_rescues(o)
        result=[:begin,result] unless o[:ruby187]||result==[:nil]#||result.first==:begin
        return result
      end

      def rescue_parsetree o
        result=parsetree o
        result.first==:begin and result=result.last unless o[:ruby187]
        result
      end

      def begin_parsetree(o)
        body,rescues,else_,ensure_=*self
        needbegin=(rescues&&!rescues.empty?) || ensure_ || @empty_ensure
        result=parsetree(o)
        needbegin and result=[:begin, result] unless result.first==:begin
        result
      end

      def lvalue
        return nil
      end
#      attr_accessor :lvalue

      def unparse(o=default_unparse_options)
          result="begin "
          result+=unparse_and_rescues(o)
          result+=";end"
      end
    end

    class RescueOpNode<ValueNode
    #  include OpNode
      param_names :body, :rescues #, :else!, :ensure!
      def initialize(expr,rescueword,backup)
            replace [expr,[RescueNode[[],nil,backup]]]
      end

      def else; nil end
      def ensure; nil end

      def left; body end
      def right; rescues.action end

      alias ensure_ ensure
      alias else_ else
      alias empty_ensure ensure
      alias empty_else else

      attr_accessor :after_equals
      def op?; true end

      def special_conditions!
        nil
      end

      def to_lisp
        huh #what about rescues
        body.to_lisp
      end
 
      def parsetree(o)
          body=body()
          target=result=[]   #was: [:begin, ]

          #body,rescues,else_,ensure_=*self

          rescues=rescues().map{|resc| resc.parsetree(o)}
          target.push newtarget=[:rescue, ]
          else_=nil
          needbegin=  (BeginNode===body and body.after_equals)
          huh if needbegin and RescueOpNode===body #need test case for this
          huh if needbegin and ParenedNode===body #need test case for this
          body=body.parsetree(o) 
          body=[:begin, body] if needbegin and body.first!=:begin and !o[:ruby187]
          newtarget.push body if body
          
          newtarget.push linked_list(rescues)
          result=result.last if result.size==1
#          result=[:begin,result] 
          result
      end

      def old_rescue_parsetree o
        result=parsetree o
        result=result.last unless o[:ruby187]
        result
      end

      alias begin_parsetree parsetree
      alias rescue_parsetree parsetree

      def lvalue
        return nil 
      end

      def unparse(o=default_unparse_options)
          result= body.unparse(o)
          result+=" rescue "
          result+=rescues.first.action.unparse(o)
      end
    end

    class AssignmentRhsNode < Node #not to appear in final parse tree
      param_names :open_, :val, :close_
      def initialize(*args)
        if args.size==1: super args.first
        else super args[1]
        end
      end
      #WITHCOMMAS=UnaryStarNode|CommaOpNode|(CallSiteNode&-{:with_commas=>true})
      def is_list

        return !(WITHCOMMAS===val)
=begin
        #this should be equivalent, why doesn't it work?
        !(UnaryStarNode===val or
          CommaOpNode===val or
          CallSiteNode===val && val.with_commas==true)
#          CallSiteNode===val && !val.real_parens && val.args.size>0
=end
      end
      identity_param :is_list, true, false
    end

    class AssignNode<ValueNode
      param_names :left,:op,:right
      alias lhs left
      alias rhs right
      def initialize(*args)

        if args.size==5
          if args[3].ident=="rescue3"
            lhs,op,rescuee,op2,rescuer=*args
            rhs=RescueOpNode.new(rescuee.val,op2,rescuer)
          else
            lhs,op,bogus1,rhs,bogus2=*args
          end
        else
          lhs,op,rhs=*args
          rhs=rhs.val if AssignmentRhsNode===rhs
        end
        case lhs
        when UnaryStarNode         #look for star on lhs
          lhs=MultiAssign.new([lhs]) unless lhs.after_comma
        when ParenedNode
          if !lhs.after_comma      #look for () around lhs
          if CommaOpNode===lhs.first
            lhs=MultiAssign.new(Array.new(lhs.first))
          else
            lhs=MultiAssign.new([lhs.first])
          end
          @lhs_parens=true
          end
        when CommaOpNode: 
          lhs=MultiAssign.new lhs
          #rhs=Array.new(rhs) if CommaOpNode===rhs
        end 

        if CommaOpNode===rhs
          rhs=Array.new(rhs)
          lhs=MultiAssign.new([lhs]) unless MultiAssign===lhs
        end

        op=op.ident

        return super(lhs,op,rhs)  
        #punting, i hope the next layer can handle += and the like

=begin
        #in theory, we should do something more sophisticated, like this:
        #(but the presence of side effects in lhs will screw it up)
        if op=='='
          super
        else
          super(lhs,OpNode.new(lhs,OperatorToken.new(op.chomp('=')),rhs))
        end
=end
      end

      def multi?
        MultiAssign===left
      end

      def image; '(=)' end

      def to_lisp
        case left
        when ParenedNode; huh
        when BeginNode; huh
        when RescueOpNode; huh
        when ConstantNode; huh
        when BracketsGetNode; huh
        when VarNode
          "(set #{left.to_lisp} (#{op.chomp('=')} #{left.to_lisp} #{right.to_lisp}))"
        when CallSiteNode
        if op=='='
          "(#{left.receiver.to_lisp} #{left.name}= #{right.to_lisp})"
        else
          op_=op.chomp('=')
          varname=nil
          "(let #{varname=huh} #{left.receiver.to_lisp} "+
            "(#{varname} #{left.name}= "+
              "(#{op_} (#{varname} #{op}) #{right.to_lisp})))"
        end
        else  huh
        end
      end

      def all_current_lvars
        left.respond_to?(:all_current_lvars) ?
          left.all_current_lvars : []
      end

      def parsetree(o)
        case left
        when ParenedNode; huh
        when RescueOpNode; huh
        when BeginNode; huh
        when ConstantNode;
          left.lvalue_parsetree(o) << right.parsetree(o)

        when MultiAssign;
        lhs=left.lvalue_parsetree(o)
        rhs= right.class==Array ? right.dup : [right]
        star=rhs.pop if UnaryStarNode===rhs.last
        rhs=rhs.map{|x| x.rescue_parsetree(o)}
        if rhs.size==0
          star or fail
          rhs= star.parsetree(o)
        elsif rhs.size==1 and !star and !(UnaryStarNode===left.first)
          rhs.unshift :to_ary
        else
          rhs.unshift(:array) 
          if star
            splat=star.val.rescue_parsetree(o)
            #if splat.first==:call #I don't see how this can be right....
            #  splat[0]=:attrasgn
            #  splat[2]="#{splat[2]}=".to_sym
            #end
            rhs=[:argscat, rhs, splat] 
          end
          if left.size==1 and !(UnaryStarNode===left.first) and !(NestedAssign===left.first)
            rhs=[:svalue, rhs]
            if CallNode===left.first
              rhs=[:array, rhs]
            end
          end
        end
        if left.size==1 and BracketsGetNode===left.first and right.class==Array #hack
          lhs.last<<rhs
          lhs
        else
          lhs<< rhs
        end

        when CallSiteNode
        op=op().chomp('=')
        rcvr=left.receiver.parsetree(o)
        prop=left.name.+('=').to_sym
        args=right.rescue_parsetree(o)
        UnaryStarNode===right and args=[:svalue, args]
        if op.empty?
          [:attrasgn, rcvr, prop, [:array, args] ]
        else
          [:op_asgn2, rcvr,prop,  op.to_sym, args]
        end

        when BracketsGetNode
        args=left.params
        if op()=='='
          result=left.lvalue_parsetree(o) #[:attrasgn, left[0].parsetree(o), :[]=]
          result.size==3 and result.push [:array]
          rhs=right.rescue_parsetree(o)
          UnaryStarNode===right and rhs=[:svalue, rhs]
          if args 
            result[-1]=[:argspush,result[-1]] if UnaryStarNode===args.last
          #else result[-1]=[:zarray]
          end
          result.last << rhs
          result            
          
        else
=begin
          args&&=args.map{|x| x.parsetree(o)}.unshift(:array)
          splat=args.pop if :splat==args.last.first
          if splat and left.params.size==1
            args=splat
          elsif splat
            args=[:argscat, args, splat.last]
          end
=end
          lhs=left.parsetree(o)
          if lhs.first==:fcall
            rcvr=[:self]
            args=lhs[2]
          else
            rcvr=lhs[1]
            args=lhs[3]
          end
          args||=[:zarray]
          result=[
            :op_asgn1, rcvr, args,
            op().chomp('=').to_sym, 
            right.rescue_parsetree(o)
          ]
        end

        when VarNode
        node_type=left.varname2assigntype
        if /^(&&|\|\|)=$/===op()
          
          return ["op_asgn_#{$1[0]==?& ? "and" : "or"}".to_sym, 
                  left.parsetree(o),
                  [node_type, left.ident.to_sym, 
                   right.rescue_parsetree(o)]
                 ]
        end

        if op()=='='
          rhs=right.rescue_parsetree(o)
          UnaryStarNode===right and rhs=[:svalue, rhs]
          
#          case left
#          when VarNode: 
               [node_type, left.ident.to_sym, rhs]
#          else [node_type, left.data[0].parsetree(o), left.data[1].data[0].ident.+('=').to_sym  ,[:array, rhs]]
#          end

=begin these branches shouldn't be necessary now
        elsif node_type==:op_asgn2
          [node_type, @data[0].data[0].parsetree(o), 
            @data[0].data[1].data[0].ident.+('=').to_sym,
            op().ident.chomp('=').to_sym,
             @data[2].parsetree(o)
          ]
        elsif node_type==:attrasgn
          [node_type]
=end
        else
          [node_type, left.ident.to_sym,
            [:call,
             left.parsetree(o), 
               op().chomp('=').to_sym, 
             [:array, right.rescue_parsetree(o)]
            ]
          ]
        end
        else 
          huh
        end
      end

      def unparse(o=default_unparse_options)
        result=lhs.lhs_unparse(o)
        result="(#{result})" if defined? @lhs_parens
        result+op+
          (rhs.class==Array ? 
            rhs.map{|rv| rv.unparse o}.join(',') :
            rhs.unparse(o) 
          )
      end
    end

    class MultiAssignNode < ValueNode #obsolete
      param_names :left,:right

      #not called from parse table

      def parsetree(o)
        lhs=left.dup
        if UnaryStarNode===lhs.last
          lstar=lhs.pop
        end
        lhs.map!{|x| 
          res=x.parsetree(o)
          res[0]=x.varname2assigntype if VarNode===x
          res
        }
        lhs.unshift(:array) if lhs.size>1 or lstar
        rhs=right.map{|x| x.parsetree(o)}
        if rhs.size==1
          if rhs.first.first==:splat 
            rhs=rhs.first
          else
            rhs.unshift :to_ary
          end
        else
          rhs.unshift(:array) 
          if rhs[-1][0]==:splat
            splat=rhs.pop[1]
            if splat.first==:call 
              splat[0]=:attrasgn
              splat[2]="#{splat[2]}=".to_sym
            end
            rhs=[:argscat, rhs, splat] 
          end
        end
        result=[:masgn, lhs, rhs]
        result.insert(2,lstar.data.last.parsetree(o)) if lstar
        result

      end
    end

    class AssigneeList< ValueNode #abstract
      def initialize(data)
        data.each_with_index{|datum,i|
          if ParenedNode===datum
            first=datum.first
            list=case first
            when CommaOpNode; Array.new(first)
            when UnaryStarNode,ParenedNode; [first]
            end 
            data[i]=NestedAssign.new(list) if list
          end
        }
        replace data
      end

      def  unparse o=default_unparse_options
        map{|lval| lval.lhs_unparse o}.join(', ')      
      end

      def old_parsetree o
        lhs=data.dup
        if UnaryStarNode===lhs.last
          lstar=lhs.pop.val
        end
        lhs.map!{|x| 
          res=x.parsetree(o)
          res[0]=x.varname2assigntype if VarNode===x
          res
        }
        lhs.unshift(:array) if lhs.size>1 or lstar
        result=[lhs]
        if lstar.respond_to? :varname2assigntype
          result << lstar.varname2assigntype 
        elsif lstar #[]=, attrib=, or A::B=
          huh  
        else #do nothing
        end
        result

      end

      def parsetree(o) 
        data=self
        data.empty? and return nil 
#        data=data.first if data.size==1 and ParenedNode===data.first and data.first.size==1
        data=Array.new(data)
        star=data.pop if UnaryStarNode===data.last
        result=data.map{|x| x.lvalue_parsetree(o) }
=begin
        {
          if VarNode===x
            ident=x.ident
            ty=x.varname2assigntype
#            ty==:lasgn and ty=:dasgn_curr
            [ty, ident.to_sym] 
          else
            x=x.parsetree(o)
            if x[0]==:call
              x[0]=:attrasgn
              x[2]="#{x[2]}=".to_sym
            end
            x
          end
        }
=end
        if result.size==0   #just star on lhs
          star or fail
          result=[:masgn]
          result.push nil #why??? #if o[:ruby187]
          result.push star.lvalue_parsetree(o)
        elsif result.size==1 and !star and !(NestedAssign===data.first)  #simple lhs, not multi
          result=result.first
        else
          result=[:masgn, [:array, *result]]
          result.push nil if (!star or DanglingCommaNode===star) #and o[:ruby187]
          result.push star.lvalue_parsetree(o) if star and not DanglingCommaNode===star
        end
        result
      end



      def all_current_lvars
        result=[]
        each{|lvar|
          lvar.respond_to?(:all_current_lvars) and
            result.concat lvar.all_current_lvars 
        }
        return result
      end

      def lvalue_parsetree(o); parsetree(o) end
    end
    class NestedAssign<AssigneeList
      def parsetree(o)
        result=super
        result<<nil #why???!! #if o[:ruby187]
        result
      end
#      def parsetree(o)
#        [:masgn, *super]
#      end
      def unparse o=default_unparse_options
        "("+super+")"
      
      end
    end


    class MultiAssign<AssigneeList; end
    class BlockParams<AssigneeList; 
      def initialize(data)
        item=data.first if data.size==1
        #elide 1 layer of parens if present
        if ParenedNode===item
          item=item.first
          data=CommaOpNode===item ? Array.new(item) : [item]
          @had_parens=true
        end

        super(data)
      end

      def unparse o=default_unparse_options
        if defined? @had_parens
          "|("+super+")|" 
        else
          "|"+super+"|" 
        end
      end

      def parsetree o
        result=super
        result.push nil if UnaryStarNode===self.last || size>1 #and o[:ruby187]
        result
      end
    end

    class AccessorAssignNode < ValueNode #obsolete
      param_names :left,:dot_,:property,:op,:right

      def to_lisp
        if op.ident=='='
          "(#{left.to_lisp} #{property.ident}= #{right.to_lisp})"
        else
          op=op().ident.chomp('=')
          varname=nil
          "(let #{varname=huh} #{left.to_lisp} "+
            "(#{varname} #{property.ident}= "+
              "(#{op} (#{varname} #{property.ident}) #{right.to_lisp})))"
        end
      end

      def parsetree(o)
        op=op().ident.chomp('=')
        rcvr=left.parsetree(o)
        prop=property.ident.<<(?=).to_sym
        rhs=right.parsetree(o)
        if op.empty?
          [:attrasgn, rcvr, prop, [:array, args] ]
        else
          [:op_asgn2, rcvr,prop,  op.to_sym, args]
        end
      end
    end
 
    module KeywordOpNode
      def unparse o=default_unparse_options
        [left.unparse(o),' ',op,' ',right.unparse(o)].to_s
      end
    end

    module LogicalNode
      include KeywordOpNode
      def initialize(left,op,right)
        @opmap=op[0,1]
        case op
        when "&&"; op="and"
        when "||"; op="or"
        end
        #@reverse= op=="or"
        #@op=op
        @module=LogicalNode
        replace [left,right]
        (size-1).downto(0){|i|
          expr=self[i]
          if LogicalNode===expr and expr.op==op 
            self[i,1]=Array.new expr
            opmap[i,0]=expr.opmap
          end
        }
      end
      attr_reader :opmap

      OP_EXPAND={?o=>"or", ?a=>"and", ?&=>"&&", ?|=>"||", nil=>""}
      OP_EQUIV={?o=>"or", ?a=>"and", ?&=>"and", ?|=>"or"}

      def reverse
        /\A[o|]/===@opmap      
      end
      def op
        OP_EQUIV[@opmap[0]]
      end

      #these 3 methods are defined in RawOpNode too, hence these
      #definitions are ignored. grrrrrrr.
      def unparse o=default_unparse_options
        result=''
      
        each_with_index{|expr,i|
          result.concat expr.unparse(o)
          result.concat ?\s
          result.concat OP_EXPAND[@opmap[i]]
          result.concat ?\s
        }
        return result
      end
      def left(*args,&block)
        method_missing(:left,*args,&block)  
      end
      def right(*args,&block)
        method_missing(:right,*args,&block)
      end

      def parsetree(o)
        result=[].replace(self).reverse
        last=result.shift.begin_parsetree(o)
        first=result.pop
        result=result.inject(last){|sum,x| 
          [op.to_sym, x.begin_parsetree(o), sum]
        }
        [op.to_sym, first.rescue_parsetree(o), result]
      end

      def special_conditions!
        each{|x| 
          if x.respond_to? :special_conditions! and !(ParenedNode===x)
            x.special_conditions! 
          end
        }
      end
    end

    module WhileOpNode
      include KeywordOpNode
      def condition; right end
      def consequent; left end
      def initialize(val1,op,val2)
        self[1]=op
        @reverse=false
        @module=WhileOpNode
        @loop=true
        @test_first= !( BeginNode===val1 )
        condition.special_conditions! if condition.respond_to? :special_conditions!
      end

      def while; condition end
      def do; consequent end

      def parsetree(o)
        cond=condition.rescue_parsetree(o)
        body=consequent.parsetree(o)
        !@test_first and
          body.size == 2 and
            body.first == :begin and
              body=body.last
        if cond.first==:not
          kw=:until
          cond=cond.last
        else
          kw=:while
        end
        [kw, cond, body, (@test_first or body==[:nil])]
      end

      
    end

    module UntilOpNode
      include KeywordOpNode
      def condition; right end
      def consequent; left end
      def initialize(val1,op,val2)
        self[1]=op
        @reverse=true
        @loop=true
        @test_first= !( BeginNode===val1 ) 
        @module=UntilOpNode
        condition.special_conditions! if condition.respond_to? :special_conditions!
      end

      def while; negate condition end
      def do; consequent end

      def parsetree(o)
        cond=condition.rescue_parsetree(o)
        body=consequent.parsetree(o)
        !@test_first and
          body.size == 2 and
            body.first == :begin and
              body=body.last
        if cond.first==:not
          kw=:while
          cond=cond.last
        else
          kw=:until
        end
        tf=@test_first||body==[:nil]
#        tf||= (!consequent.body and !consequent.else and #!consequent.empty_else and
#               !consequent.ensure and !consequent.empty_ensure and consequent.rescues.empty?
#              ) if BeginNode===consequent
        [kw, cond, body, tf]
      end
    end

    module UnlessOpNode
      include KeywordOpNode
      def condition; right end
      def consequent; left end
      def initialize(val1,op,val2)
        self[1]=op
        @reverse=true
        @loop=false
        @module=UnlessOpNode
        condition.special_conditions! if condition.respond_to? :special_conditions!
      end

      def if; condition end
      def then; nil end
      def else; consequent end
      def elsifs; [] end

      def parsetree(o)
        cond=condition.rescue_parsetree(o)
        actions=[nil, consequent.parsetree(o)]
        if cond.first==:not
          actions.reverse!
          cond=cond.last
        end
        [:if, cond, *actions]
      end
    end

    module IfOpNode
      include KeywordOpNode
      def condition; right end
      def consequent; left end
      def initialize(left,op,right)
        self[1]=op
        @reverse=false
        @loop=false
        @module=IfOpNode
        condition.special_conditions! if condition.respond_to? :special_conditions!
      end

      def if; condition end
      def then; consequent end
      def else; nil end
      def elsifs; [] end

      def parsetree(o)
        cond=condition.rescue_parsetree(o)
        actions=[consequent.parsetree(o), nil]
        if cond.first==:not
          actions.reverse!
          cond=cond.last
        end
        [:if, cond, *actions]
      end
    end

    class CallSiteNode<ValueNode
      param_names :receiver, :name, :params, :blockparams, :block
      alias blockargs blockparams
      alias block_args blockargs
      alias block_params blockparams

      def initialize(method,open_paren,param_list,close_paren,block)
        @not_real_parens=!open_paren || open_paren.not_real?

        case param_list
        when CommaOpNode
          #handle inlined hash pairs in param list (if any)
#          compr=Object.new
#          def compr.==(other) ArrowOpNode===other end
          param_list=Array.new(param_list)
          first=last=nil
          param_list.each_with_index{|param,i| 
            break first=i if ArrowOpNode===param
          }
          (1..param_list.size).each{|i| param=param_list[-i]
            break last=-i if ArrowOpNode===param
          }
          if first
            arrowrange=first..last
            arrows=param_list[arrowrange]
            h=HashLiteralNode.new(nil,arrows,nil)
            h.startline=arrows.first.startline
            h.endline=arrows.last.endline
            param_list[arrowrange]=[h]
          end
        
        when ArrowOpNode
          h=HashLiteralNode.new(nil,param_list,nil)
          h.startline=param_list.startline
          h.endline=param_list.endline
          param_list=[h]
#        when KeywordOpNode
#          fail "didn't expect '#{param_list.inspect}' inside actual parameter list"
        when nil
        else
          param_list=[param_list]
        end

        if block
          @do_end=block.do_end
          blockparams=block.params
          block=SequenceNode[*block.body] #||[]
        end
        @offset=method.offset
        method=method.ident
        fail unless String===method
        super(nil,method,param_list,blockparams,block)
        #receiver, if any, is tacked on later
      end

      def real_parens; !@not_real_parens end

      def unparse o=default_unparse_options
        fail if block==false
        result=[
         receiver&&receiver.unparse(o)+'.',name,      
         real_parens ? '(' : (' ' if params),
         params&&params.map{|param|  unparse_nl(param,o,'',"\\\n")+param.unparse(o)  }.join(', '),
         real_parens ? ')' : nil,
        
         block&&[
           @do_end ? " do " : "{", 
             block_params&&block_params.unparse(o),
             " ",
             block.unparse(o),
           @do_end ? " end" : "}"
         ]
        ]
        return result.to_s
      end

      def image
        result="(#{receiver.image if receiver}.#{name})"
      end
     
      def with_commas
         !real_parens and args.size>0
      end

#      identity_param :with_commas, false, true

      def lvalue_parsetree(o)
        result=parsetree(o)
        result[0]=:attrasgn
        result[2]="#{result[2]}=".to_sym
        result
      end

      def lvalue
        return @lvalue if defined? @lvalue
        @lvalue=true
      end
      attr_writer :lvalue

      identity_param :lvalue, nil, true

      def to_lisp
        "(#{receiver.to_lisp} #{self[1..-1].map{|x| x.to_lisp}.join(' ')})"
      end

      alias args params
      alias rcvr receiver

      def set_receiver!(expr)
        self[0]=expr
      end

      def parsetree_with_params o
        args=args()||[]
        if (UnOpNode===args.last and args.last.ident=="&@")
          lasti=args.size-2
          unamp_expr=args.last.val
        else
          lasti=args.size-1
        end
        methodname= name
        methodsym=methodname.to_sym
        is_kw= RubyLexer::FUNCLIKE_KEYWORDS&~/^(BEGIN|END|raise)$/===methodname

        result=
        if lasti==-1
          [(@not_real_parens and /[!?]$/!~methodname and !unamp_expr) ? 
             :vcall : :fcall, methodsym
          ]
        elsif (UnaryStarNode===args[lasti])
          if lasti.zero?
            [:fcall, methodsym, args.first.rescue_parsetree(o)]
          else
            [:fcall, methodsym, 
             [:argscat, 
               [:array, *args[0...lasti].map{|x| x.rescue_parsetree(o) } ], 
                  args[lasti].val.rescue_parsetree(o) 
             ]
            ]
          end         
        else
          singlearg= lasti.zero?&&args.first
          [:fcall, methodsym, 
           [:array, *args[0..lasti].map{|x| x.rescue_parsetree(o) } ]
          ]
        end

        result[0]=:vcall if block #and /\Af?call\Z/===result[0].to_s

        if is_kw and !receiver
          if singlearg and "super"!=methodname
            result=[methodsym, singlearg.parsetree(o)]
            result.push(true) if methodname=="yield" and ArrayLiteralNode===singlearg #why???!!
            return result
          end
          breaklike=  /^(break|next|return)$/===methodname
          if @not_real_parens
              return [:zsuper] if "super"==methodname and !args()
          else
              return [methodsym, [:nil]] if breaklike and args.size.zero?
          end
          result.shift 
          arg=result[1]
          result[1]=[:svalue,arg] if arg and arg[0]==:splat and breaklike
        end

        if receiver
          result.shift if result.first==:vcall or result.first==:fcall #if not kw
          result=[:call, receiver.rescue_parsetree(o), *result]
        end

        if unamp_expr
#          result[0]=:fcall if lasti.zero?
          result=[:block_pass, unamp_expr.rescue_parsetree(o), result]
        end

        return result
      end

      def parsetree(o)
        callsite=parsetree_with_params o
        return callsite unless blockparams or block
        call=name
        callsite[0]=:fcall  if callsite[0]==:call or callsite[0]==:vcall
        unless receiver
          case call
          when "BEGIN"
            if o[:quirks]
              return []
            else
              callsite=[:preexe] 
            end
          when "END"; callsite=[:postexe]
          end
        else
          callsite[0]=:call if callsite[0]==:fcall
        end

        if blockparams
          bparams=blockparams.dup
          lastparam=bparams.last
          amped=bparams.pop.val if UnOpNode===lastparam and lastparam.op=="&@"
          bparams=bparams.parsetree(o)||0
          if amped
            bparams=[:masgn, [:array, bparams]] unless bparams==0 or bparams.first==:masgn
            bparams=[:block_pass, amped.lvalue_parsetree(o), bparams]
          end
        else
          bparams=nil
        end
        result=[:iter, callsite, bparams]
        unless block.empty?
          body=block.parsetree(o)
          if curr_vars=block.lvars_defined_in
            curr_vars-=blockparams.all_current_lvars if blockparams
            if curr_vars.empty?
              result.push body
            else
              curr_vars.map!{|cv| [:dasgn_curr, cv.to_sym] }
              (0...curr_vars.size-1).each{|i| curr_vars[i]<<curr_vars[i+1] }
              #body.first==:block ? body.shift : body=[body]
              result.push((body)) #.unshift curr_vars[0]))
            end
          else
            result.push body
          end
        end 
        result
      end

      def blockformals_parsetree data,o  #dead code?
        data.empty? and return nil 
        data=data.dup
        star=data.pop if UnaryStarNode===data.last
        result=data.map{|x| x.parsetree(o) }
=begin
 {          if VarNode===x
            ident=x.ident
            ty=x.varname2assigntype
#            ty==:lasgn and ty=:dasgn_curr
            [ty, ident.to_sym] 
          else
            x=x.parsetree(o)
            if x[0]==:call
              x[0]=:attrasgn
              x[2]="#{x[2]}=".to_sym
            end
            x
          end
        }
=end
        if result.size==0
          star or fail
          result=[:masgn, star.parsetree(o).last]
        elsif result.size==1 and !star
          result=result.first
        else
          result=[:masgn, [:array, *result]]
          if star 
            old=star= star.val
            star=star.parsetree(o)
            if star[0]==:call
              star[0]=:attrasgn
              star[2]="#{star[2]}=".to_sym
            end

            if VarNode===old
              ty=old.varname2assigntype
#              ty==:lasgn and ty=:dasgn_curr
              star[0]=ty
            end
            result.push star
          end
        end
        result
      end
    end

    class CallNode<CallSiteNode #normal method calls
      def initialize(method,open_paren,param_list,close_paren,block)
        MethNameToken===method or fail
        super
      end
    end
    class KWCallNode<CallSiteNode #keywords that look (more or less) like methods
      def initialize(method,open_paren,param_list,close_paren,block)
        KeywordToken===method or fail
        super
      end
    end

    class BlockFormalsNode<Node #obsolete
      def initialize(goalpost1,param_list,goalpost2)
        param_list or return super()
        CommaOpNode===param_list and return super(*Array.new(param_list))
        super(param_list)
      end

      def to_lisp
        "(#{data.join' '})"
      end

      def parsetree(o)
        empty? ? nil :
          [:dasgn_curr, 
            *map{|x| 
              (VarNode===x) ? x.ident.to_sym : x.parsetree(o)
            }
          ]
      end
    end

    class BlockNode<ValueNode #not to appear in final parse tree
      param_names :params,:body
      def initialize(open_brace,formals,stmts,close_brace)
        case stmts
        when SequenceNode; stmts=Array.new(stmts)
        when nil; stmts=[]
        else stmts=[stmts]
        end
        
        formals&&=BlockParams.new(Array.new(formals))
        @do_end=true unless open_brace.not_real?
        super(formals,stmts)
      end

      attr_reader :do_end

      def to_lisp
        "(#{params.to_lisp} #{body.to_lisp})"
      end

      def parsetree(o) #obsolete
        callsite=@data[0].parsetree(o)
        call=@data[0].data[0]
        callsite[0]=:fcall  if call.respond_to? :ident
        if call.respond_to? :ident
          case call.ident
          when "BEGIN" 
            if o[:quirks]
              return []
            else
              callsite=[:preexe] 
            end
          when "END"; callsite=[:postexe]
          end
        end
        result=[:iter, callsite, @data[1].parsetree(o)]
        result.push @data[2].parsetree(o) if @data[2]
        result
      end
    end

    class NopNode<ValueNode
      def initialize(*args)
        super()
      end

      def unparse o=default_unparse_options
        ''      
      end

      def to_lisp
        "()"
      end

      alias image to_lisp

      def to_parsetree(*options)
        []
      end
    end

=begin
    class ObjectNode<ValueNode
      def initialize
        super
      end
      def to_lisp
        "Object"
      end

      def parsetree(o)
        :Object
      end
    end
=end 

    class CallWithBlockNode<ValueNode #obsolete
      param_names :call,:block
      def initialize(call,block)
        KeywordCall===call and extend KeywordCall
        super
      end

      def to_lisp
        @data.first.to_lisp.chomp!(")")+" #{@data.last.to_lisp})"
      end
    end

    class StringNode<ValueNode
      def initialize(token)
        if HerePlaceholderToken===token 
          str=token.string
          @char=token.quote
        else
          str=token
          @char=str.char
        end
        @modifiers=str.modifiers #if str.modifiers
        super( *with_string_data(str) )

        @open=token.open
        @close=token.close
        @bs_handler=str.bs_handler

        if /[\[{]/===@char
          @parses_like=split_into_words(str)
        end

        return

#this should have been taken care of by with_string_data        
        first=shift
        delete_if{|x| ''==x }
        unshift(first)

#escape translation now done later on
        map!{|strfrag|
          if String===strfrag
            str.translate_escapes strfrag
          else
            strfrag
          end
        }
      end

      def translate_escapes(str)
        rl=RubyLexer.new("(string escape translation hack...)",'')
        result=str.dup
        seq=result.to_sequence
        rl.instance_eval{@file=seq}
        repls=[]
        i=0
        #ugly ugly ugly
        while i<result.size and bs_at=result.index(/\\./m,i)
          seq.pos=$~.end(0)-1
          ch=rl.send(@bs_handler,"\\",@open[-1,1],@close)
          result[bs_at...seq.pos]=ch
          i=bs_at+ch.size
        end

        return  result
      end

      def old_cat_initialize(*tokens) #not needed anymore?
        token=tokens.shift
  
        tokens.size==1 or fail "string node must be made from a single string token"

        newdata=with_string_data(*tokens)

        case token
        when HereDocNode: 
          token.list_to_append=newdata
        when StringNode: #do nothing
        else fail "non-string token class used to construct string node"
        end
        replace token.data

#        size%2==1 and last<<newdata.shift
        if size==1 and String===first and String===newdata.first
          first << newdata.shift
        end
        concat newdata
        
        @implicit_match=false
      end

      ESCAPABLES={}
      EVEN_NUM_BSLASHES=/(^|[^\\])((?:\\\\)*)/
      def unparse o=default_unparse_options
        o[:linenum]+=@open.count("\n")
        result=[@open,unparse_interior(o),@close,@modifiers].to_s  
        o[:linenum]+=@close.count("\n")
        return result
      end

      def escapable open=@open,close=@close
        unless escapable=ESCAPABLES[open]
          maybe_crunch='\\#' if %r{\A["`/\{]\Z} === @char and open[1] != ?q and open != "'" #"
          #crunch (#) might need to be escaped too, depending on what @char is
          escapable=ESCAPABLES[open]=
            /[#{Regexp.quote open[-1,1]+close}#{maybe_crunch}]/
        end
        escapable             
      end

      def unparse_interior o,open=@open,close=@close,escape=nil
        escapable=escapable(open,close)
        result=map{|substr|
          if String===substr

            #hack: this is needed for here documents only, because their
            #delimiter is changing.
            substr.gsub!(escape){|ch| ch[0...-1]+"\\"+ch[-1,1]} if escape

            o[:linenum]+=substr.count("\n") if o[:linenum]

            substr
          else
            ['#{',substr.unparse(o),'}']
          end
        }
        result
      end

      def image; '(#@char)' end

      def delete_extraneous_ivars!
        @parses_like.delete_extraneous_ivars! if defined? @parses_like
        return super
      end

      def walk(*args,&callback)
        return @parses_like.walk(*args,&callback) if defined? @parses_like
        super
      end

      def depthwalk(*args,&callback)
        return @parses_like.depthwalk(*args,&callback) if defined? @parses_like
        super
      end

      def special_conditions!
        @implicit_match= @char=="/"
      end

      attr_reader :modifiers,:char#,:data
      alias type char

      def with_string_data(token)
#        token=tokens.first

#        data=tokens.inject([]){|sum,token|
#          data=elems=token.string.elems
          data=elems=
            case token
            when StringToken; token.elems
            when HerePlaceholderToken; token.string.elems
            else raise "unknown string token type: #{token}:#{token.class}"
            end
#          sum.size%2==1 and sum.last<<elems.shift
#          sum+elems
#        } 
#        endline=@endline
        1.step(data.length-1,2){|i|
          tokens=data[i].ident.dup
          line=data[i].linenum

          #replace trailing } with EoiToken
          (tokens.size-1).downto(0){|j| 
             tok=tokens[j]
             break(tokens[j..-1]=[EoiToken.new('',nil,tokens[j].offset)]) if tok.ident=='}' 
          }
          #remove leading {
          tokens.each_with_index{|tok,j| break(tokens.delete_at j) if tok.ident=='{' }

          if tokens.size==1 and VarNameToken===tokens.first
            data[i]=VarNode.new tokens.first
            data[i].endline=token.endline
          else
            #parse the token list in the string inclusion
            parser=Thread.current[:$RedParse_parser]
            klass=parser.class
            data[i]=klass.new(tokens, "(string inclusion)",1,[],{:rubyversion=>parser.rubyversion}).parse
          end
        } #if data
#        was_nul_header= (String===data.first and data.first.empty?) #and o[:quirks]
        last=data.size-1

        #remove (most) empty string fragments
        last.downto(1){|frag_i| 
          frag=data[frag_i]
          String===frag or next
          next unless frag.empty? 
          next if frag_i==last #and o[:quirks]
          next if data[frag_i-1].endline != data[frag_i+1].endline #and o[:quirks]
                  #prev and next inclusions on different lines
          data.slice!(frag_i)
        }
#        data.unshift '' if was_nul_header

        return data
      end

      def endline= endline
        each{|frag| 
          frag.endline||=endline if frag.respond_to? :endline
        }

        super
      end

      def to_lisp
        return %{"#{first}"} if size<=1 and @char=='"'
        huh
      end

      EVEN_BSS=/(?:[^\\\s\v]|\G)(?:\\\\)*/

      DQ_ESC=/(?>\\(?>[CM]-|c)?)/
      DQ_EVEN=%r[
                  (?:
                   \A |
                   [^\\c-] |
                   (?>\A|[^\\])c |
                   (?> [^CM] | (?>\A|[^\\])[CM] )-
                  )              #not esc
                  #{DQ_ESC}{2}*  #an even number of esc
             ]omx
      DQ_ODD=/#{DQ_EVEN}#{DQ_ESC}/omx
      SQ_ESC=/\\/
      SQ_EVEN=%r[
                  (?:  \A | [^\\]  )  #not esc
                  #{SQ_ESC}{2}*       #an even number of esc
             ]omx
      SQ_ODD=/#{SQ_EVEN}#{SQ_ESC}/omx
      def split_into_words strtok
        return unless /[{\[]/===@char
        result=ArrayLiteralNode[]
        result << StringNode['',{:@char=>'"',:@open=>@open,:@close=>@close,:@bs_handler=>@bs_handler}]
        proxy=dup
        proxy[0]=proxy[0][/\A(?:\s|\v)+(.*)\Z/,1] if /\A(?:\s|\v)/===proxy[0]
#        first[/\A(?:\s|\v)+/]='' if /\A(?:\s|\v)/===first #uh-oh, changes first
        proxy.each{|x|
          if String===x
#            x=x[/\A(?:\s|\v)+(.*)\Z/,1] if /\A[\s\v]/===x
if false
            #split on ws preceded by an even # of backslashes or a non-backslash, non-ws char
            #this ignores backslashed ws
            #save the thing that preceded the ws, it goes back on the token preceding split
            double_chunks=x.split(/( #{EVEN_BSS} | (?:[^\\\s\v]|\A|#{EVEN_BSS}\\[\s\v]) )(?:\s|\v)+/xo,-1)
            chunks=[]
            (0..double_chunks.size).step(2){|i| 
              chunks << #strtok.translate_escapes \
                double_chunks[i,2].to_s #.gsub(/\\([\s\v\\])/){$1}
            }
else
            #split on ws, then ignore ws preceded by an odd number of esc's
            #esc is \ in squote word array, \ or \c or \C- or \M- in dquote
            chunks_and_ws=x.split(/([\s\v]+)/,-1)
            start=chunks_and_ws.size; start-=1 if start&1==1
            chunks=[]
            i=start+2; 
            while (i-=2)>=0 
              ch=chunks_and_ws[i]||""
              if i<chunks_and_ws.size and ch.match(@char=="[" ? /#{SQ_ODD}\Z/omx : /#{DQ_ODD}\Z/omx)
                ch<< chunks_and_ws[i+1][0,1]
                if chunks_and_ws[i+1].size==1
                  ch<< chunks.shift
                end
              end
              chunks.unshift ch
            end
end

            chunk1= chunks.shift          
            if chunk1.empty?
              #do nothing more
            elsif String===result.last.last
              result.last.last << chunk1
            else
              result.last.push chunk1
            end
#            result.last.last.empty? and result.last.pop
            result.concat chunks.map{|chunk| 
              StringNode[chunk,{:@char=>'"',:@open=>@open,:@close=>@close,:@bs_handler=>@bs_handler}]
            }
          else
            #result.last << x
            unless String===result.last.last
              result.push StringNode["",{:@char=>'"',:@open=>@open,:@close=>@close,:@bs_handler=>@bs_handler}]
            end
            result.last.push x
#            result.push StringNode["",x,{:@char=>'"',:@open=>@open,:@close=>@close,:@bs_handler=>@bs_handler}]
          end
        } 
        result.shift if StringNode&-{:size=>1, :first=>''}===result.first
        result.pop if StringNode&-{:size=>1, :first=>''}===result.last

        return result
      end

      CHAROPT2NUM={
        ?x=>Regexp::EXTENDED,
        ?m=>Regexp::MULTILINE,
        ?i=>Regexp::IGNORECASE,
        ?o=>8,
      }
      CHARSETFLAG2NUM={
        ?n=>0x10,
        ?e=>0x20,
        ?s=>0x30,
        ?u=>0x40
      }
      CHAROPT2NUM.default=0
      CHARSETFLAG2NUM.default=0
      DOWNSHIFT_STRING_TYPE={
        :dregx=>:lit,
        :dregx_once=>:lit,
        :dstr=>:str,
        :dxstr=>:xstr,
      }
      def parsetree(o)
        if size==1
          val=translate_escapes first
          type=case @char
               when '"',"'"; :str
               when '/'
                 numopts=0
                 charset=0
                 @modifiers.each_byte{|ch| 
                   if ch==?o
                     type=:dregx_once
                   elsif numopt=CHAROPT2NUM[ch].nonzero?
                     numopts|=numopt
                   elsif set=CHARSETFLAG2NUM[ch].nonzero?
                     charset=set
                   else fail
                   end
                 }
                 val=Regexp.new val,numopts|charset
                 :lit
               when '[','{'
                 return @parses_like.parsetree(o)
=begin
                 double_chunks=val.split(/([^\\]|\A)(?:\s|\v)/,-1)
                 chunks=[]
                 (0..double_chunks.size).step(2){|i| 
                   chunks << double_chunks[i,2].to_s.gsub(/\\(\s|\v)/){$1}
                 }
#                 last=chunks
#                 last.last.empty? and last.pop if last and !last.empty?

                 words=chunks#.flatten
                 words.shift if words.first.empty? unless words.empty?
                 words.pop if words.last.empty? unless words.empty?
                 return [:zarray] if words.empty? 
                 return words.map{|word| [:str,word]}.unshift(:array)
=end
               when '`'; :xstr
               else raise "dunno what to do with #@char<StringToken"
               end
          result=[type,val]
        else
          saw_string=false
          vals=[]
          each{|elem| 
            case elem
            when String
              elem=translate_escapes elem
              if saw_string
                result=[:str, elem]
              else
                saw_string=true
                result=elem
              end
              vals.push result
            when NopNode
              vals.push [:evstr]
            when Node #,VarNameToken
              res=elem.parsetree(o)
              if res.first==:str and @char != '{'
                vals.push res
              elsif res.first==:dstr and @char != '{'
                vals.push [:str, res[1]], *res[2..-1]
              else
                vals.push [:evstr, res]
              end
            else fail "#{elem.class} not expected here"
            end
          }
          while vals.size>1 and vals[1].first==:str
            vals[0]+=vals.delete_at(1).last
          end
          #vals.pop if vals.last==[:str, ""]

          type=case @char
               when '"'; :dstr
               when '/'
                 type=:dregx
                 numopts=charset=0
                 @modifiers.each_byte{|ch| 
                   if ch==?o
                     type=:dregx_once
                   elsif numopt=CHAROPT2NUM[ch].nonzero?
                     numopts|=numopt
                   elsif set=CHARSETFLAG2NUM[ch].nonzero?
                     charset=set
                   end
                 }
                 vals.push numopts|charset unless numopts|charset==0
                 val=/#{val}/
                 type
               when '{'
                 return @parses_like.parsetree(o)
=begin
                 vals[0]=vals[0].sub(/\A(\s|\v)+/,'') if /\A(\s|\v)/===vals.first
                 merged=Array.new(vals)
                 result=[]
                 merged.each{|i|
                   if String===i
                     next if /\A(?:\s|\v)+\Z/===i 
                     double_chunks=i.split(/([^\\]|\A)(?:\s|\v)/,-1)
                     chunks=[]
                     (0..double_chunks.size).step(2){|ii| 
                       chunks << double_chunks[ii,2].to_s.gsub(/\\(\s|\v)/){$1}
                     }
                     words=chunks.map{|word| [:str,word]}
                     if !result.empty? and frag=words.shift and !frag.last.empty?
                       result[-1]+=frag
                     end
                     result.push( *words )
                   else
                     result.push [:str,""] if result.empty?
                     if i.first==:evstr and i.size>1 and i.last.first==:str
                       if String===result.last[-1]
                         result.last[-1]+=i.last.last
                       else
                         result.last[0]=:dstr
                         result.last.push(i.last)
                       end
                     else
                       result.last[0]=:dstr
                       result.last.push(i)
                     end
                   end
                 }
                 return result.unshift(:array)
=end
               when '`'; :dxstr
               else raise "dunno what to do with #@char<StringToken"
               end

          if vals.size==1
            vals=[/#{vals[0]}/] if :dregx==type or :dregx_once==type
            type=DOWNSHIFT_STRING_TYPE[type]
          end
          result= vals.unshift(type)
        end
        result=[:match, result] if defined? @implicit_match and @implicit_match
        return result
      end
    end

    class HereDocNode<StringNode
      param_names :token
      def initialize(token)
        token.node=self
        super(token)
        @startline=token.string.startline
      end
      attr_accessor :list_to_append
#      attr :token

      def saw_body!     #not used
        replace with_string_data(token)
        @char=token.quote
        if @list_to_append
          size%2==1 and token << @list_to_append.shift
          push( *@list_to_append )
          remove_instance_variable :@list_to_append
        end
      end


      def flattened_ivars_equal?(other)
        StringNode===other
      end

      def unparse o=default_unparse_options
        inner=unparse_interior o,@char,@char,
                case @char
                when "'" #single-quoted here doc is a special case; 
                         #\ and ' are not special within it
                         #(and therefore always escaped if converted to normal squote str)
                         /['\\]/ 
                when '"'; /#{DQ_EVEN}"/
                when "`"; /#{DQ_EVEN}`/
                else fail
                end
        [@char, inner, @char].to_s
      end
    end

    class LiteralNode<ValueNode
      param_names :val
      attr_accessor :offset
      def initialize(old_val)
        @offset=old_val.offset
        val=old_val.ident
        case old_val
        when SymbolToken
          case val[1]
          when ?' #'
            assert !old_val.raw.has_str_inc?
            val=old_val.raw.translate_escapes(old_val.raw.elems.first).to_sym
          when ?" #"
            if old_val.raw.has_str_inc?
              val=StringNode.new(old_val.raw) #ugly hack: this isn't literal
            else
              val=old_val.raw.translate_escapes(old_val.raw.elems.first).to_sym
            end
          else #val=val[1..-1].to_sym
            if StringToken===old_val.raw
              val=old_val.raw.translate_escapes(old_val.raw.elems.first).to_sym
            else
              val=old_val.raw.to_sym
            end
          end
        when NumberToken 
          case val
          when /\A-?0([^.]|\Z)/; val=val.oct
          when /[.e]/i; val=val.to_f
          else val=val.to_i
          end
        end
        super(val)
      end

      def bare_method
        Symbol===val || StringNode===val
      end

      identity_param :bare_method, nil, false, true

      def image; "(#{':' if Symbol===val}#{val})" end

      def to_lisp
        return val.to_s
      end

      Inf="999999999999999999999999999999999.9e999999999999999999999999999999999999"
      Nan="****shouldnt ever happen****"

      def unparse o=default_unparse_options
        val=val()
        case val 
        when StringNode #ugly hack
          ":"+
            val.unparse(o)
        when Float
          s= "%#{Float::DIG}.#{Float::DIG}f"%val
          case s
          when /-inf/i; s="-"+Inf
          when /inf/i;  s=    Inf
          when /nan/i;  s=    Nan
          else
            fail unless [s.to_f].pack("d")==[val].pack("d")
          end
          s
        else val.inspect
        end
      end

      def parsetree(o)
        val=val()
        case val 
        when StringNode #ugly hack
          result= val.parsetree(o)
          result[0]=:dsym
          return result
=begin
        when String 
          #float or real string? or keyword?
          val=
          case val
          when Numeric: val
          when Symbol: val
          when String: val
          when "true": true
          when "false": false
          when "nil": nil
          when "self": return :self
          when "__FILE__": "wrong-o"
          when "__LINE__": "wrong-o"
          else fail "unknown token type in LiteralNode: #{val.class}"
          end
=end
        end
        return [:lit,val]
      end
    end

    class VarLikeNode<ValueNode #nil,false,true,__FILE__,__LINE__,self
      param_names :name
      def initialize(name,*more)
        if name.ident=='(' 
          #simulate nil
          replace ['nil']
        else
          replace [name.ident]
          @value=name.respond_to?(:value) && name.value
        end
      end

      alias ident name
      
      def image; "(#{name})" end
 
      def to_lisp
        name
      end

      def unparse o=default_unparse_options
        name      
      end

      def parsetree(o)
        if (defined? @value) and @value
          type=:lit
          val=@value
          if name=="__FILE__"
            type=:str
            val="(string)" if val=="-"
          end
          [type,val]
        else
          [name.to_sym]
        end
      end
    end

    class ArrayLiteralNode<ValueNode
      def initialize(lbrack,contents,rbrack)
        contents or return super()
        if CommaOpNode===contents
          super( *contents )
        else
          super contents
        end
      end

      def image; "([])" end

      def unparse o=default_unparse_options
        "["+map{|item| unparse_nl(item,o,'')+item.unparse(o)}.join(', ')+"]"
      end

      def parsetree(o)
        size.zero? and return [:zarray]
        normals,star,amp=param_list_parse(self,o)
        result=normals.unshift :array
        if star
          if size==1
            result=star
          else
            result=[:argscat, result, star.last] 
          end
        end
        result
      end

    end
    #ArrayNode=ValueNode

    class BracketsSetNode < ValueNode #obsolete
      param_names :left,:assign_,:right
      def parsetree(o)
        [:attrasgn, left.data[0].parsetree(o), :[]=, 
         [:array]+Array(left.data[1]).map{|x| x.parsetree(o)}<< right.parsetree(o)
        ]
      end
    end

    class BracketsModifyNode < ValueNode #obsolete
      param_names :left,:assignop,:right
      def initialize(left,assignop,right)
        super
      end

      def parsetree(o)
        bracketargs=@data[0].data[1]
        bracketargs=bracketargs ? bracketargs.map{|x| x.parsetree(o)}.unshift(:array) : [:zarray]
        [:op_asgn1, @data[0].data[0].parsetree(o), bracketargs, 
         data[1].ident.chomp('=').to_sym, data[2].parsetree(o)]
      end
    end

    class IfNode < ValueNode
      param_names :condition,:consequent,:elsifs,:otherwise
      def initialize(iftok,condition,thentok,consequent,elsifs,else_,endtok)
        if else_ 
          else_=else_.val or @empty_else=true
        end
        condition.special_conditions! if condition.respond_to? :special_conditions!
        super(condition,consequent,elsifs,else_)
        @reverse=  iftok.ident=="unless"
        if @reverse
          @iftok_offset=iftok.offset
          fail "elsif not allowed with unless" unless elsifs.empty?
        end
      end
      alias if condition
      alias then consequent
      alias else otherwise
      alias else_ else
      alias if_ if
      alias then_ then

      attr_reader :empty_else

      def unparse o=default_unparse_options
        result=@reverse ? "unless " : "if "
        result+="#{condition.unparse o}"
        result+=unparse_nl(consequent,o)+"#{consequent.unparse(o)}" if consequent
        result+=unparse_nl(elsifs.first,o)+elsifs.map{|n| n.unparse(o)}.to_s if elsifs
        result+=unparse_nl(else_,o)+"else "+else_.unparse(o) if else_
        result+=";else " if defined? @empty_else
        result+=";end"
        return result
      end

      def image; "(if)" end

      def if
        if @reverse
          negate condition, @iftok_offset
        else
          condition
        end
      end

      def then
        @reverse ? otherwise : consequent
      end

      def else
        @reverse ? consequent : otherwise
      end

      def to_lisp
        if elsifs.empty? 
          "(#{@reverse ? :unless : :if} #{condition.to_lisp}\n"+
          "(then #{consequent.to_lisp})\n(else #{otherwise.to_lisp}))"
        else
          "(cond (#{condition.to_lisp} #{consequent.to_lisp})\n"+
                elsifs.map{|x| x.to_lisp}.join("\n")+
                "\n(else #{otherwise.to_lisp})"+
          "\n)"
        end
      end
 
      def parsetree(o)
        elsepart=otherwise.parsetree(o) if otherwise
        elsifs.reverse_each{|elsifnode|
          elsepart=elsifnode.parsetree(o) << elsepart
        }
        cond=condition.rescue_parsetree(o)
        actions=[
              consequent&&consequent.parsetree(o), 
              elsepart
        ]
        if cond.first==:not
          cond=cond.last
          reverse=!@reverse
        else
          reverse=@reverse
        end
        actions.reverse! if reverse
        result=[:if, cond, *actions]
        return result
      end
    end

    class ElseNode<Node #not to appear in final tree
      param_names :elseword_,:val
      alias body val

      def image; "(else)" end

      def to_lisp
        "(else #{body.to_lisp})"
      end
    end

    class EnsureNode<Node #not to appear in final tree
      param_names :ensureword_, :val
      alias body val
      def image; "(ensure)" end
      def parsetree(o) #obsolete?
        (body=body()) ? body.parsetree(o) : [:nil]
      end
    end

    class ElsifNode<Node
      param_names(:elsifword_,:condition,:thenword_,:consequent)
      def initialize(elsifword,condition,thenword,consequent)
        condition.special_conditions! if condition.respond_to? :special_conditions!
        super(condition,consequent)
      end

      alias if condition
      alias elsif if
      alias then consequent

      def image; "(elsif)" end

      def unparse o=default_unparse_options
        "elsif #{condition.unparse o}#{unparse_nl(consequent,o)}#{consequent.unparse o};"
      end

      def to_lisp
        "("+condition.to_lisp+" "+consequent.to_lisp+")"
      end

      def parsetree(o) #obsolete?
        [:if, condition.rescue_parsetree(o), consequent&&consequent.parsetree(o), ]
      end
    end

    class LoopNode<ValueNode
      #this class should be abstract and have 2 concrete descendants for while and until
      param_names :condition, :body
      def initialize(loopword,condition,thenword,body,endtok)
        condition.special_conditions! if condition.respond_to? :special_conditions!
        super(condition,body)
        @reverse=  loopword.ident=="until"
        @loopword_offset=loopword.offset
      end

      alias do body

      def image; "(#{loopword})" end

      def unparse o=default_unparse_options
        [@reverse? "until " : "while ",
         condition.unparse(o), unparse_nl(body||self,o),
         body&&body.unparse(o),
         ";end"
        ].to_s
      end

      def while
        @reverse ? negate(condition, @loopword_offset) : condition
      end

      def until
        @reverse ? condition : negate(condition, @loopword_offset)
      end

      def to_lisp
        body=body()
        "(#{@reverse ? :until : :while} #{condition.to_lisp}\n#{body.to_lisp})"
      end

      def parsetree(o)
        cond=condition.rescue_parsetree(o)
        if cond.first==:not
          reverse=!@reverse
          cond=cond.last
        else
          reverse=@reverse
        end 
        [reverse ? :until : :while, cond, body&&body.parsetree(o), true]
      end
    end

    class CaseNode<ValueNode
      param_names(:case!,:whens,:else!)
      alias condition case
      alias otherwise else

      def initialize(caseword, condition, semi, whens, otherwise, endword)
        if otherwise
          otherwise=otherwise.val or @empty_else=true
        end
        super(condition,whens,otherwise)
      end

      attr_reader :empty_else

      def unparse o=default_unparse_options
        result="case #{condition&&condition.unparse(o)}"+
               whens.map{|wh| wh.unparse o}.to_s

        result += unparse_nl(otherwise,o)+"else "+otherwise.unparse(o) if otherwise
        result += ";end"

        return result
      end

      def image; "(case)" end

      def to_lisp
        "(case #{case_.to_lisp}\n"+
          whens.map{|x| x.to_lisp}.join("\n")+"\n"+
          "(else #{else_.to_lisp}"+
        "\n)"
      end
  
      def parsetree(o)
        [:case, condition&&condition.parsetree(o)]+ 
           whens.map{|whennode| whennode.parsetree(o)}+
        [otherwise&&otherwise.parsetree(o)]
      end
    end

    class WhenNode<Node #not to appear in final tree?
      param_names(:whenword_,:when!,:thenword_,:then!)
      def initialize(whenword,when_,thenword,then_)
        when_=Array.new(when_) if CommaOpNode===when_
        super(when_,then_)
      end
      alias body then
      alias consequent then
      alias condition when

      def image; "(when)" end

      def unparse o=default_unparse_options
        result=unparse_nl(self,o)+"when "
        result+=condition.class==Array ? 
                  condition.map{|cond| cond.unparse(o)}.join(',') : 
                  condition.unparse(o) 
        result+=unparse_nl(consequent,o)+consequent.unparse(o) if consequent
        result
      end

      def to_lisp
        unless Node|Token===condition
          "(when (#{condition.map{|cond| cond.to_lisp}.join(" ")}) #{
            consequent&&consequent.to_lisp
          })"
        else
          "(#{when_.to_lisp} #{then_.to_lisp})"
        end
        

      end

      def parsetree(o)
        conds=
          if Node|Token===condition
            [condition.rescue_parsetree(o)]
          else
            condition.map{|cond| cond.rescue_parsetree(o)}
          end
        if conds.last[0]==:splat
          conds.last[0]=:when
          conds.last.push nil
        end
        [:when, [:array, *conds],
          consequent&&consequent.parsetree(o)
        ]
      end
    end

    class ForNode<ValueNode
      param_names(:forword_,:for!,:inword_,:in!,:doword_,:do!,:endword_)
      def initialize(forword,for_,inword,in_,doword,do_,endword)
        #elide 1 layer of parens if present
        for_=for_.first if ParenedNode===for_
        for_=CommaOpNode===for_ ? Array.new(for_) : [for_]
        super(BlockParams.new(for_),in_,do_)
      end

      alias body do
      alias enumerable in
      alias iterator for

      def image; "(for)" end

      def unparse o=default_unparse_options
        result=unparse_nl(self,o)+"         for #{iterator.lhs_unparse(o)[1...-1]} in #{enumerable.unparse o}"
        result+=unparse_nl(body,o)+"           #{body.unparse(o)}" if body
        result+=";end"
      end

      def parsetree(o)
=begin
        case vars=@data[0]
        when Node: 
          vars=vars.parsetree(o)
          if vars.first==:call
            vars[0]=:attrasgn
            vars[2]="#{vars[2]}=".to_sym
          end
          vars
        when Array: 
          vars=[:masgn, [:array, 
                  *vars.map{|lval| 
                     res=lval.parsetree(o)
                     res[0]=lval.varname2assigntype if VarNode===lval
                     res
                   } 
               ]]
        when VarNode
          ident=vars.ident
          vars=vars.parsetree(o)
          (vars[0]=vars.varname2assigntype) rescue nil
        else fail
        end
=end

        vars=self.for.lvalue_parsetree(o)
        result=[:for, self.in.begin_parsetree(o), vars]
        result.push self.do.parsetree(o) if self.do
        result
      end

    end


    class HashLiteralNode<ValueNode
      def initialize(open,contents,close)
        case contents
        when nil; super()
        when ArrowOpNode; super(contents.first,contents.last)
        when CommaOpNode,Array
          if ArrowOpNode===contents.first
            data=[]
            contents.each{|pair|
              ArrowOpNode===pair or fail
              data.push pair.first,pair.last
            }
          else
            data=Array[*contents]
          end
          super(*data)
        end
        @no_braces=!open
      end

      def image; "({})" end

      def unparse o=default_unparse_options
        result=''
        result << "{" unless @no_braces
        (0...size).step(2){|i| 
          result<< unparse_nl(self[i],o,'')+
            self[i].unparse(o)+' => '+
            self[i+1].unparse(o)+', '
        }
        result.chomp! ', '
        result << "}" unless @no_braces
        return result
      end

      def parsetree(o)
        map{|elem| elem.rescue_parsetree(o)}.unshift :hash
      end

      def error? rubyversion=1.8
        return true if @no_arrows and rubyversion>=1.9
        return super
      end
    end

    class TernaryNode<ValueNode
      param_names :if!,:qm_,:then!,:colon_,:else!
      alias condition if
      alias consequent then
      alias otherwise else
      def initialize(if_,qm,then_,colon,else_)
        super(if_,then_,else_)
        condition.special_conditions! if condition.respond_to? :special_conditions!
      end

      def image; "(?:)" end

      def unparse o=default_unparse_options
        "#{condition.unparse o} ? #{consequent.unparse o} : #{otherwise.unparse o}"      
      end

      def elsifs; [] end

      def parsetree(o)
        cond=condition.rescue_parsetree(o)
        cond[0]=:fcall if cond[0]==:vcall and cond[1].to_s[/[?!]$/]
        [:if, cond, consequent.begin_parsetree(o), otherwise.begin_parsetree(o)]
      end
    end

    class MethodNode<ValueNode
      include HasRescue
      param_names(:defword_,:receiver,:name,:maybe_eq_,:args,:semi_,:body,:rescues,:elses,:ensures,:endword_)
      alias ensure_ ensures
      alias else_ elses
      alias ensure ensures
      alias else elses
      alias params args
      
      def initialize(defword_,header,maybe_eq_,semi_,
                     body,rescues,else_,ensure_,endword_)
        @empty_else=@empty_ensure=nil
#        if DotCallNode===header
#          header=header.data[1]
#        end
        if CallSiteNode===header
          receiver=header.receiver
          args=header.args
          header=header.name
        end
        if MethNameToken===header
          header=header.ident 
        end
        unless String===header
          fail "unrecognized method header: #{header}"
        end
        if else_
          else_=else_.val  or @empty_else=true
        end
        if ensure_
          ensure_=ensure_.val or @empty_ensure=true
        end
        replace [receiver,header,args,body,rescues,else_,ensure_]
      end

      attr_reader :empty_ensure, :empty_else

      def receiver= x
        self[0]=x      
      end

      def body= x
        self[3]=x      
      end

      def ensure_= x
        self[5]=x      
      end

      def else_= x
        self[6]=x      
      end

      def image
        "(def #{receiver.image.+('.') if receiver}#{name})"
      end

      def unparse o=default_unparse_options
        result=[
         "def ",receiver&&receiver.unparse(o)+'.',name,
           args ? '('+args.map{|arg| arg.unparse o}.join(',')+')' : unparse_nl(body||self,o)
        ]
        result<<unparse_and_rescues(o)
=begin
        body&&result+=body.unparse(o)

        result+=rescues.map{|resc| resc.unparse o}.to_s 
        result+="else #{else_.unparse o}\n"  if else_
        result+="else\n" if @empty_else
        result+="ensure #{ensure_.unparse o}\n"  if ensure_
        result+="ensure\n" if @empty_ensure
=end
        result<<";end"
        result.to_s
      end

      def to_lisp
        "(imethod #{name} is\n#{body.to_lisp}\n)\n"
        #no receiver, args, rescues, else_ or ensure_...
      end

      def parsetree(o)
        name=name().to_sym

        result=[name, target=[:scope, [:block, ]] ]
        if receiver
          result.unshift :defs, receiver.rescue_parsetree(o)
        else
          result.unshift :defn
        end

        goodies= (body or !rescues.empty? or elses or ensures or @empty_ensure) # or args())

        if unamp=args() and unamp=unamp.last and UnOpNode===unamp and unamp.op=="&@"
          receiver and goodies=true
        else 
          unamp=false
        end

        if receiver and !goodies
          target.delete_at 1 #omit :block
        else
          target=target[1]
        end

        target.push args=[:args,]
        target.push unamp.parsetree(o) if unamp

        if args()
          initvals=[]
          args().each{|arg| 
              case arg
                  when VarNode
                    args.push arg.ident.to_sym
                  when UnaryStarNode:
                    args.push "*#{arg.val.ident}".to_sym
                  when UnOpNode:
                    nil
                  when AssignNode:
                    initvals << arg.parsetree(o)
                    initvals[-1][-1]=arg.right.rescue_parsetree(o) #ugly
                    args.push arg[0].ident.to_sym
                  else 
                    fail "unsupported node type in method param list: #{arg}"
              end
          }
          unless initvals.empty?
            initvals.unshift(:block) 
            args << initvals
            #args[-2][0]==:block_arg and target.push args.delete_at(-2)
          end
        end
        target.push [:nil] if !goodies && !receiver

        #it would be better to use parsetree_and_rescues for the rest of this method,
        #just to be DRYer

        target.push ensuretarget=target=[:ensure, ] if ensures or @empty_ensure
        #simple dup won't work... won't copy extend'd modules
        body=Marshal.load(Marshal.dump(body())) if body()
        elses=elses()
        if rescues.empty?
          case body
          when SequenceNode; body << elses;elses=nil
          when nil; body=elses;elses=nil
          else nil
          end if elses
        else
          target.push target=[:rescue, ] 
          elses=elses()
        end
        if body
          if BeginNode===body||RescueOpNode===body and 
            body.rescues.empty? and !body.ensure and !body.empty_ensure and body.body and body.body.size>1
              wantblock=true
          end
          body=body.parsetree(o)
          if body.first==:block and rescues.empty? and not ensures||@empty_ensure
            if wantblock
              target.push body
            else
              body.shift 
              target.concat body
            end
          else
            #body=[:block, *body] if wantblock
            target.push body
          end
        end
        target.push linked_list(rescues.map{|rescue_| rescue_.parsetree(o) }) unless rescues.empty?
        target.push elses.parsetree(o) if elses
        ensuretarget.push ensures.parsetree(o) if ensures
        ensuretarget.push [:nil] if @empty_ensure

        return result
      end
    end

    module BareSymbolUtils
      def baresym2str(node)
        case node
        when MethNameToken;  node.ident
        when VarNode; node
        when LiteralNode
          case node.val
          when Symbol 
            node.val.to_s
          when StringNode; node.val
#          when StringToken: StringNode.new(node.val)
          else fail
          end
        end
      end

      def str_unparse(str,o)
       case str
       when VarNode; str.ident
       when "~@"; str
       when String 
         str.to_sym.inspect
         #what if str isn't a valid method or operator name? should be quoted
       when StringNode
         ":"+str.unparse(o)
       else fail
       end
      end

      def str2parsetree(str,o)
       if String===str then [:lit, str.to_sym] 
       else 
         result=str.parsetree(o)
         result[0]=:dsym
         result
       end
      end
    end

    class AliasNode < ValueNode
      include BareSymbolUtils
      param_names(:aliasword_,:to,:from)
      def initialize(aliasword,to,from)
        to=baresym2str(to)
        from=baresym2str(from)
        super(to,from)
      end

      def unparse o=default_unparse_options
        "alias #{str_unparse to,o} #{str_unparse from,o}"      
      end

      def image; "(alias)" end
      def parsetree(o)
        if VarNode===to and to.ident[0]==?$
          [:valias, to.ident.to_sym, from.ident.to_sym]
        else
          [:alias, str2parsetree(to,o), str2parsetree(from,o)]
        end
      end
    end

    class UndefNode < ValueNode
      include BareSymbolUtils
      def initialize(first,middle,last=nil)
        if last
          node,newsym=first,last
          super(*node << baresym2str(newsym))
        else
          super(baresym2str(middle))
        end
      end

      def image; "(undef)" end

      def unparse o=default_unparse_options
        "undef #{map{|name| str_unparse name,o}.join(', ')}"
      end

      def parsetree(o)
        result=map{|name| [:undef, str2parsetree(name,o)] }
        if result.size==1
          result.first
        else
          result.unshift :block 
        end
      end
    end

    class NamespaceNode<ValueNode
      include HasRescue
      def initialize(*args)
        @empty_ensure=@empty_else=nil
        super
      end
    end
 
    class ModuleNode<NamespaceNode
      param_names(:name,:body,:rescues,:else!,:ensure!)

      def initialize moduleword,name,semiword,body,rescues,else_,ensure_,endword
        else_=else_.val if else_
        ensure_=ensure_.val if ensure_
        super(name,body,rescues,else_,ensure_)        
      end

      alias else_ else
      alias ensure_ ensure

      def image; "(module #{name})" end

      def unparse o=default_unparse_options
        "module #{name.unparse o}#{unparse_nl(body||self,o)}#{unparse_and_rescues(o)};end"
      end

      def parent; nil end
      def to_lisp
        result="(#{name.ident} #{body.to_lisp} "
        #parent=@data[2]
        #result+="is #{parent.to_lisp} " if parent
       
        result+="\n"+body.to_lisp+")"
        return result
      end

      def parsetree(o)
        name=name()
        if VarNode===name
          name=name.ident.to_sym
        elsif name.nil? #do nothing
#        elsif o[:quirks]
#          name=name.constant.ident.to_sym
        else 
          name=name.parsetree(o)
        end
        result=[:module, name, scope=[:scope, ]]
        scope << parsetree_and_rescues(o) if body
        return result
      end
    end

    class ClassNode<NamespaceNode
      param_names(:name,:parent,:body,:rescues,:else!,:ensure!)
      def initialize(classword,name,semi,body,rescues, else_, ensure_, endword)
        if OpNode===name
          name,op,parent=*name
          op=="<" or fail "invalid superclass expression: #{name}"
        end
        else_=else_.val if else_
        ensure_=ensure_.val if ensure_
        super(name,parent,body,rescues,else_,ensure_)
      end

      alias else_ else
      alias ensure_ ensure

      def image; "(class #{name})" end

      def unparse o=default_unparse_options
        result="class #{name.unparse o}"
        result+=" < #{parent.unparse o}" if parent
        result+=unparse_nl(body||self,o)+"#{unparse_and_rescues(o)};end"
        return result
      end

      def to_lisp
        result="(class #{name.to_lisp} "
        result+="is #{parent.to_lisp} " if parent
       
        result+="\n"+body.to_lisp+")"
        return result
      end

      def parsetree(o)
        name=name()
        if VarNode===name
          name=name.ident.to_sym
        elsif name.nil? #do nothing
#        elsif o[:quirks]
#          name=name.constant.ident.to_sym
        else 
          name=name.parsetree(o)
        end
        result=[:class, name, parent&&parent.parsetree(o), scope=[:scope,]]
        scope << parsetree_and_rescues(o) if body
        return result
      end
    end

    class MetaClassNode<NamespaceNode
      param_names :val, :body, :rescues,:else!,:ensure!
      def initialize classword, leftleftword, val, semiword, body, rescues,else_,ensure_, endword
        else_=else_.val if else_
        ensure_=ensure_.val if ensure_
        super(val,body,rescues,else_,ensure_)
      end 

      alias expr val
      alias object val
      alias obj val
      alias receiver val
      alias name val

      alias ensure_ ensure
      alias else_ else

      def image; "(class<<)" end

      def unparse o=default_unparse_options
        "class << #{obj.unparse o}#{unparse_nl(body||self,o)}#{unparse_and_rescues(o)};end"
      end

      def parsetree(o)
        result=[:sclass, expr.parsetree(o), scope=[:scope]]
        scope << parsetree_and_rescues(o) if body
        return result
      end
    end

    class RescueHeaderNode<Node  #not to appear in final tree
      param_names :exceptions,:varname
      def initialize(rescueword,arrowword,exceptions,thenword)
        case exceptions
        when nil
        when VarNode:
          if arrowword
            exvarname=exceptions
            exceptions=nil
            arrowword=nil
          end
        when ArrowOpNode: 
          exvarname=exceptions.last
          exceptions=exceptions.first
        when CommaOpNode
          lastexpr=exceptions.last
          if ArrowOpNode===lastexpr
            exceptions[-1]=lastexpr.left
            exvarname=lastexpr.right
          end
          exceptions=Array.new(exceptions)
        end
        fail if arrowword
#        fail unless VarNode===exvarname || exvarname.nil?
        super(exceptions,exvarname)
      end

      def image; "(rescue=>)" end
    end

    class RescueNode<Node
      param_names :exceptions,:varname,:action
      def initialize(rescuehdr,action,semi)
        exlist=rescuehdr.exceptions||[]
        exlist=[exlist] unless exlist.class==Array
        fail unless exlist.class==Array
        super(exlist,rescuehdr.varname,action)
      end

      def unparse o=default_unparse_options
        xx=exceptions.map{|exc| exc.unparse o}.join(',')
        unparse_nl(self,o)+
        "rescue #{xx} #{varname&&'=> '+varname.lhs_unparse(o)}#{unparse_nl(action||self,o)}#{action&&action.unparse(o)}"
      end

      def parsetree(o)
        result=[:resbody, nil]
        fail unless exceptions.class==Array
        ex=#if Node===exceptions; [exceptions.rescue_parsetree(o)] 
           #elsif exceptions
             exceptions.map{|exc| exc.rescue_parsetree(o)} 
           #end
        if !ex or ex.empty? #do nothing
        elsif ex.last.first!=:splat
          result[1]= [:array, *ex]
        elsif ex.size==1
          result[1]= ex.first
        else
          result[1]= [:argscat, ex[0...-1].unshift(:array), ex.last[1]]
        end
        VarNode===varname and offset=varname.offset
        action=if varname
          SequenceNode.new(
            AssignNode.new( 
              varname, 
              KeywordToken.new("=",offset),
              VarNode.new(VarNameToken.new("$!",offset))
            ),nil,action()
          )
        else
          action()
        end
        result.push action.parsetree(o) if action
        result
      end

      def image; "(rescue)" end
    end

    class BracketsGetNode<ValueNode
      param_names(:receiver,:lbrack_,:params,:rbrack_)
      def initialize(receiver,lbrack,params,rbrack)
        params=case params
        when CommaOpNode; Array.new params
        when nil
        else [params]
        end
        super(receiver,params)
      end

      def image; "(#{receiver.image}.[])" end

      def unparse o=default_unparse_options
        [ receiver.unparse(o).sub(/\s+\Z/,''),
          '[',
          params&&params.map{|param| param.unparse o}.join(','),
          ']'
        ].to_s
      end

      def parsetree(o)
        result=parsetree_no_fcall o
        o[:quirks] and VarLikeNode===receiver and receiver.name=='self' and
          result[0..2]=[:fcall,:[]] 
        return result
      end

      def parsetree_no_fcall o
        params=params()
        output,star,amp=param_list_parse(params,o)
#        receiver=receiver.parsetree(o)
        result=[:call, receiver.rescue_parsetree(o), :[], output]
        if params
          if star and params.size==1
            output.concat star
          else
            output.unshift :array 
            result[-1]=[:argscat, output, star.last] if star
          end
        else
          result.pop
        end
        return result
      end
      def lvalue_parsetree(o)
        result=parsetree_no_fcall o
        result[0]=:attrasgn
        result[2]=:[]=
        result
      end

      def lvalue
        return @lvalue if defined? @lvalue
        @lvalue=true
      end
      attr_writer :lvalue
      identity_param :lvalue, nil, true
    end


    class StartToken<Token  #not to appear in final tree
      def initialize; end

      def image; "(START)" end
      alias to_s image


    end #beginning of input marker

    class EoiToken
      #hack hack: normally, this should never
      #be called, but it may be when input is empty now.
      def to_parsetree(*options)
        []
      end
    end

    class GoalPostToken<Token  #not to appear in final tree
      def initialize(offset); @offset=offset end
      def ident; "|" end
      attr :offset

      def image; "|" end
    end

    class GoalPostNode<Node  #not to appear in final tree
      def initialize(offset); @offset=offset end
      def ident; "|" end
      attr :offset

      def image; "|" end
    end

    module ErrorNode
      def error?(x=nil) @error end
      alias msg error?
    end


    class MisparsedNode<ValueNode
      include ErrorNode
      param_names :open,:middle,:close_
      alias begin open
      alias what open

      def image; "misparsed #{what}" end

      #pass the buck to child ErrorNodes until there's no one else
      def blame
        middle.each{|node| 
          node.respond_to? :blame and return node.blame 
        }
        return self
      end
 
      def error? x=nil
        inner=middle.grep(MisparsedNode).first and return inner.error?( x )
        "#@endline: misparsed #{what}: #{middle.map{|node| node&&node.image}.join(' ')}" 
      end
      alias msg error?
    end

#  end

end
=begin a (formal?) description
  NodeMatcher=
    Recursive(nodematcher={},
      Node&-{:subnodes=>NodeList = 
               Recursive(nodelist={},
                 +[(nodematcher|nodelist|nil).*])
            }

  #Nodes can also have attributes which don't appear in subnodes
  #this is where ordinary values (symbols, strings, numbers, true/false/nil) are kept
=end
