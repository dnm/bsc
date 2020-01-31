
# Scripts to generate instance specific synthesis in Bluespec SystemVerilog

# Overview:
#   Uses Bluespec's typeclass and overloading to match a module's instantiation
#   with a specific instance which may instantiate a synthesized module.
#   The general flow is:
#      1) compile with bsc as normal
#      2) specifiy the packages and module for a instance specific syntheis and
#         automatically generate typeclass and default instances for these modules.
#      3) Manually edit file to include the generated file (<package>.include.bsv)
#      4) Manually edit file to change module names to used typeclass
#         <mkModule>  -> <mkModule>_Synth
#      5) compile with bsc again.
#      6) Search for messages listing missing instances and command to automatically
#         generate execute the missing instance.  Run these commands to generate an
#         instance for each missing type
#      7) Add provisos (MakeInst_<module> #( <IfcType>#( ) ) ) in polymorphic module
#         to avoid
#      8) compile with bsc again.
#      9) review message for missing instance and


# Usage:
#   % package require InstSynth
#   % namespace import ::InstSynth::*
#   # To create the "generated include" file for a package with a
#   # typeclass for overloading of a module (Step 2)
#   # Output in <package>.include.bsv (note file is erased with this invokation
#   % genTypeClass <package> { <module1> <module2> .. }
#   # To generate specific instances execute (Step 6)
#   # Outputs are appended in <package>.include.bsv
#   % genSpecificInst <package> <module> <type>
#
#   # to generate a synthesize module wrapper
#   % genSynthMod <package> <module> <type>

# Limitations:
# -- Modules which have polymorphic arguments will not match a specific instances,
#    unless the types of the arguments are defined.  E.g.
#    mkX_Syth (0) cannot be resolved,  but  mkS_Synth ( Bit#(32)'(0) ) will work.
# -- Modules which have an argument which must be a compile time constant
#    cannot produce a synthesizable module.

package require Bluetcl
package require utils ;

namespace eval InstSynth {

    namespace export  \
        genTypeClass \
        genSpecificInst \
        genSynthMod

    variable fileExt "include.bsv"

    # generate the typeclass and a default instance for module
    proc genTypeClass { package modules } {
        variable fileExt

        # check that package is there and loadable
        condLoadPackages $package

        set outfile ${package}.$fileExt
        set OF [open $outfile w]

        puts $OF "// DO NOT Edit"
        puts $OF "// File automatically generated by Bluespec InstSynth.tcl"
        foreach mod $modules {
            puts $OF ""
            puts $OF [genTC $package $mod]
            puts $OF [genDefaultInst $package $mod]
            set pro [genProvisosToAdd $package $mod ]

            puts "\nTypeclass [instName $mod], with member [memName $mod] has been defined in: ${package}.$fileExt"
            puts "replace modules \"$mod\"  with \"[memName $mod]\""
            puts "and add proviso to containing polymorphic modules:  \"$pro\"\n"
        }
        close $OF

    }

    proc genSpecificInst { package module types } {
        variable fileExt
        # check that package is there and loadable
        condLoadPackages $package

        set outfile ${package}.$fileExt
        set OF [open $outfile a]

        puts $OF [genSynthMod $package $module $types]
        puts $OF [genSynthInst $package $module $types]
        set iname [join $types ", "]
        puts "Instance ($iname) for Typeclass [instName $module], has been added to: $outfile"
        close $OF
    }

    # the typeclass definition
    proc genTC { package module } {
        set minfo [getModuleDetail $package $module]
        set arguments [getInfo $minfo arguments]
        set argWithNames [genArgumentStr $arguments]
        set pargsL [getPolyArgTypes $arguments]
        lappend pargsL ifc_t
        set pargs [list]
        foreach a $pargsL {
            lappend pargs "type $a"
        }
        set pargs [join $pargs ", "]

        set s [list "" \
               "typeclass [instName $module] #($pargs);" \
               "    module [memName $module] ($argWithNames ifc_t ifc) ;" \
               "endtypeclass" \
               ]
        join $s "\n"
    }

    proc genProvisosToAdd { package module } {
        set minfo [getModuleDetail $package $module]
        set arguments [getInfo $minfo arguments]
        set ifc [utils::head [getInfo $minfo interface]]
        set pargs [genExtraClassTypeArgs $arguments]

        set ret "[instName $module] #($pargs $ifc)"
    }

    # A default instance of the type class
    proc genDefaultInst { package module } {
        set minfo [getModuleDetail $package $module]
        set provisos [getInfo $minfo provisos]
        set provisos [genProvisosStr $provisos]

        set ifc [utils::head [getInfo $minfo interface]]
        set arguments [getInfo $minfo arguments]
        set argname   [genArgNameStr $arguments]
        set argWithNames [genArgumentStr $arguments]
        set pargs [genExtraClassTypeArgs $arguments]
        set othertypes [getPolyArgNames $arguments]

        set s [list "" \
               "instance [instName $module] #( $pargs $ifc )" \
               "    $provisos ;" \
               "" \
               "    module [memName $module] ($argWithNames $ifc ifc) ;" \
               "        let __i <- $module $argname ;" \
               "        messageM (\"No concrete definition of $module for type \" +" \
               "                   (printType (typeOf (__i))));" \
               "        messageM (\"Execute: InstSynth::genSpecificInst $package $module {\" +" \
               "                    $othertypes " \
               "                    \" {\" + (printType (typeOf(asIfc (__i)))) + \"}\" " \
               "                    + \" }\"  );" \
               "        return __i ;" \
               "    endmodule" \
               "endinstance" \
               ]
        join $s "\n"
    }


    # (printType (typeOf (x1))) +
    proc getPolyArgNames {argTypes} {
        set i 1
        set ret [list]
        foreach a $argTypes {
            if {[isPolyType $a]} {
                lappend ret x${i}
            }
            incr i
        }
        set s [list]
        foreach r $ret {
            lappend s "\" {\" +"
            lappend s "(printType (typeOf ($r))) +"
            lappend s "\"} \" +"
        }
        join $s " "
    }

    proc genProvisosStr { prov } {
        if { $prov == "" } { return "" }
        set plist [list]
        foreach p $prov {
            lappend plist $p
        }
        set plist [join $plist ",\n          "]
        set ret [list "provisos (" $plist ")"]
        join $ret ""
    }

    # returns "t1 x1, t2 x2, ..."  with trailing comma
    proc genArgumentStr { as } {
        if { $as == "" } { return "" }
        set plist [list]
        set i 1;
        foreach a $as {
            lappend plist "$a x$i"
            incr i
        }
        set plist [join $plist ", "]
        return "$plist, "
    }

    # return  "(x1, x2, etc)"
    proc genArgNameStr { as } {
        if { $as == "" } { return "" }
        set plist [list]
        set i 1;
        foreach a $as {
            lappend plist "x$i"
            incr i
        }
        set plist [join $plist ", "]
        return "($plist)"
    }

    proc genExtraClassTypeArgs { as } {
        set pargs [getPolyArgTypes $as]
        if { $pargs == "" } {
            return ""
        }
        lappend pargs " "
        join $pargs ", "
    }

    # returns filtered list of argument types
    proc getPolyArgTypes { as } {
        set ret [list]
        foreach a $as {
            if {[isPolyType $a]} {
                lappend ret $a
            }
        }
        return $ret
    }
    proc isPolyType { tc } {
        catch "Bluetcl::type full $tc" td
        if {[lsearch -exact $td polymorphic] != -1 } {
            puts stderr "Type $tc as module argument may not be supported."
            return true
        } elseif {$td == "Variable"} {
            return true
        }
        return false ;
    }

    proc genSynthMod { package module types } {
        condLoadPackages $package
        set suff [typeToStr $types]

        set minfo [getModuleDetail $package $module]
        set arguments [getInfo $minfo arguments]
        set argnames  [genArgNameStr $arguments]
        # set dargs     [genArgumentStr $arguments]
        set dargs     [mergeType $arguments $types]
        set ifcType   [lindex $types end]

        set s [list "" \
                   "// " \
                   "(* synthesize *)" \
                   "module ${module}_${suff} ($dargs $ifcType ifc ) ;" \
                   "    let __i <- $module $argnames ;" \
                   "    return __i ;" \
                   "endmodule" \
                  ]
        join $s "\n"
    }

    # A default instance of the type class
    proc genSynthInst { package module types } {
        set suff [typeToStr $types]
        set sname ${module}_${suff}

        set minfo [getModuleDetail $package $module]
        set arguments [getInfo $minfo arguments]
        set argnames  [genArgNameStr $arguments]
        #set dargs     [genArgumentStr $arguments]
        set dargs     [mergeType $arguments $types]
        set typeL     [join $types ", "]
        set ifcType   [lindex $types end]

        set s [list "" \
                   "instance [instName $module] \#( $typeL ) ;" \
                   "    module [memName $module] ($dargs $ifcType ifc );" \
                   "        let __i <- ${sname} $argnames ;" \
                   "        messageM(\"Using $sname for $module of type: \" +" \
                   "                  (printType (typeOf (__i))));" \
                   "         return __i ;"\
                   "     endmodule" \
                   "endinstance" \
                  ]
        join $s "\n"
    }

    proc mergeType { argT ctypes } {
        set i 0
        set c 0
        set ret [list]
        foreach a $argT {
            incr i
            if { [isPolyType $a] } {
                set t [lindex $ctypes $c]
                incr c
            } else {
                set t $a
            }
            lappend ret "$t x${i}, "
        }
        join $ret " "
    }

    ################################################################
    # interface to bluetcl
    proc getModuleDetail { package module } {
        set funcs [Bluetcl::defs func $package]
        set det ""
        foreach f $funcs {
            if { [unQualType [lindex $f 1]] == $module } {
                set det $f
                break ;
            }
        }
        if { $det == "" } {
            error "Error: Module \"$module\" was not found in package \"$package\""
        }
        return $det
    }

    proc getInfo { info field } {
        set det ""
        foreach i $info {
            if { [lindex $i 0] == $field } {
                set det [lindex $i 1]
                break;
            }
        }
        return $det
    }

    ################################################################
    # Utilities
    proc condLoadPackages { pack } {
        set loaded [Bluetcl::bpackage list]
        set fnd [lsearch -exact $loaded $pack]
        if { $fnd == -1 } {
            if { [catch "Bluetcl::bpackage load $pack" err] } {
                puts stderr $err
                puts stderr "Cannot open package"
                error $err
            }
        }
    }

    proc typeToStr { type } {
        regsub -all {[ \{\}:,(\#)]+} "(${type})" "_" str
        return $str
    }
    proc instName { module } {
        return "MakeInst_${module}"
    }
    proc memName { module } {
        return "${module}_Synth"
    }
    proc unQualType { t } {
        regsub "^.*::" $t "" newt
        return $newt
    }


}
package provide InstSynth 1.0
