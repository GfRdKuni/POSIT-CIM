# ==============================================================================
# File    : run_innovus_ablation_core.tcl
# Project : posit_cim_28nm
# Purpose : Innovus P&R flow for cim_top and TT ablation cores.
#
# Recommended location:
#   /path/to/projects/posit_cim_28nm/pnr/run_innovus_ablation_core.tcl
#
# Driver:
#   /path/to/projects/posit_cim_28nm/pnr/run_innovus_ablation.sh
#
# Notes:
#   1. Uses confirmed 10lm7X2RUTRDL Cadence tech LEF.
#   2. Reads mixed-Vt cell LEFs and mixed-Vt timing .libs.
#   3. create_rc_corner uses -T, not -temperature, for this Innovus 19.14 setup.
#   4. Without native QRC/capTable, Innovus timing/SPEF is approximate.
#      Final STA should preferably use StarRC/RCXT SPEF.
#   5. posit_rf_16x128 is synthesized standard-cell logic, not a hard macro.
#   6. SI-driven route is disabled because this flow is not using SI signoff.
#   7. Post-route timing/optimization enables OCV to avoid IMPOPT-7027/6080.
# ==============================================================================

# ------------------------------------------------------------------------------
# 0. User variables injected by shell driver
# ------------------------------------------------------------------------------
if {![info exists DESIGN_NAME]} { set DESIGN_NAME "cim_top_abl_dec" }
if {![info exists OUT_TAG]}     { set OUT_TAG "abl_dec_tt0p9v25c" }
if {![info exists CORNER_ID]}   { set CORNER_ID "tt0p9v25c" }

if {![info exists DIE_W]}       { set DIE_W 400.0 }
if {![info exists DIE_H]}       { set DIE_H 400.0 }
if {![info exists CORE_MARGIN]} { set CORE_MARGIN 20.0 }
if {![info exists PLACE_DENSITY]} { set PLACE_DENSITY 0.65 }

# Optional native Cadence RC files. Usually empty in this environment.
if {![info exists QRC_TECH_FILE]} { set QRC_TECH_FILE "" }
if {![info exists CAP_TABLE]}     { set CAP_TABLE "" }

# ------------------------------------------------------------------------------
# 1. Paths
# ------------------------------------------------------------------------------
set PROJ_ROOT "/path/to/projects/posit_cim_28nm"
set SYN_ROOT  "${PROJ_ROOT}/syn"
set PNR_ROOT  "${PROJ_ROOT}/pnr"
set RUN_ROOT  "${PNR_ROOT}/runs_${OUT_TAG}"
set RPT_DIR   "${RUN_ROOT}/reports"
set OUT_DIR   "${RUN_ROOT}/outputs"
set LOG_DIR   "${RUN_ROOT}/logs"

file mkdir $PNR_ROOT
file mkdir $RUN_ROOT
file mkdir $RPT_DIR
file mkdir $OUT_DIR
file mkdir $LOG_DIR

set NETLIST "${SYN_ROOT}/outputs_${OUT_TAG}/${DESIGN_NAME}_${OUT_TAG}.v"
set SDC     "${SYN_ROOT}/outputs_${OUT_TAG}/${DESIGN_NAME}_${OUT_TAG}.sdc"

set TSMC_HOME "/path/to/licensed_pdk/tsmcN28/TSMCHOME"
set NLDM_ROOT "${TSMC_HOME}/digital/Front_End/timing_power_noise/NLDM"

# Confirmed in smoke flow.
set TECH_LEF "/path/to/licensed_pdk/tsmcN28/PRTF_EDI_28nm_Cad_V19_1a/PR_tech/Cadence/LefHeader/HVH/tsmcn28_10lm7X2RUTRDL.tlef"

# Mixed-Vt standard-cell LEFs confirmed by user.
set CELL_LEFS [list \
    "${TSMC_HOME}/digital/Back_End/lef/tcbn28hpcplusbwp30p140_110a/lef/tcbn28hpcplusbwp30p140.lef" \
    "${TSMC_HOME}/digital/Back_End/lef/tcbn28hpcplusbwp30p140hvt_110a/lef/tcbn28hpcplusbwp30p140hvt.lef" \
    "${TSMC_HOME}/digital/Back_End/lef/tcbn28hpcplusbwp30p140lvt_110a/lef/tcbn28hpcplusbwp30p140lvt.lef" \
    "${TSMC_HOME}/digital/Back_End/lef/tcbn28hpcplusbwp30p140uhvt_140b/lef/tcbn28hpcplusbwp30p140uhvt.lef" \
    "${TSMC_HOME}/digital/Back_End/lef/tcbn28hpcplusbwp30p140ulvt_140b/lef/tcbn28hpcplusbwp30p140ulvt.lef" \
]

# Mixed-Vt TT timing libs.
set LIB_FILES [list \
    "${NLDM_ROOT}/tcbn28hpcplusbwp30p140_180a/tcbn28hpcplusbwp30p140${CORNER_ID}.lib" \
    "${NLDM_ROOT}/tcbn28hpcplusbwp30p140hvt_180a/tcbn28hpcplusbwp30p140hvt${CORNER_ID}.lib" \
    "${NLDM_ROOT}/tcbn28hpcplusbwp30p140lvt_180a/tcbn28hpcplusbwp30p140lvt${CORNER_ID}.lib" \
    "${NLDM_ROOT}/tcbn28hpcplusbwp30p140uhvt_180b/tcbn28hpcplusbwp30p140uhvt${CORNER_ID}.lib" \
    "${NLDM_ROOT}/tcbn28hpcplusbwp30p140ulvt_180a/tcbn28hpcplusbwp30p140ulvt${CORNER_ID}.lib" \
]

# GDS streamOut map for 1p10m+ut-alrdl_7x2r / 10lm7X2RUTRDL.
set GDS_MAP "/path/to/licensed_pdk/tsmcN28/PRTF_EDI_28nm_Cad_V19_1a/PR_tech/Cadence/GdsOutMap/gdsout_7X2R.map"

# Mixed-Vt stdcell GDS. Missing GDS only disables merge, not the main P&R flow.
set STD_GDS_CANDIDATES [list \
    "${TSMC_HOME}/digital/Back_End/gds/tcbn28hpcplusbwp30p140_110a/tcbn28hpcplusbwp30p140.gds" \
    "${TSMC_HOME}/digital/Back_End/gds/tcbn28hpcplusbwp30p140hvt_110a/tcbn28hpcplusbwp30p140hvt.gds" \
    "${TSMC_HOME}/digital/Back_End/gds/tcbn28hpcplusbwp30p140lvt_110a/tcbn28hpcplusbwp30p140lvt.gds" \
    "${TSMC_HOME}/digital/Back_End/gds/tcbn28hpcplusbwp30p140uhvt_140a/tcbn28hpcplusbwp30p140uhvt.gds" \
    "${TSMC_HOME}/digital/Back_End/gds/tcbn28hpcplusbwp30p140ulvt_140a/tcbn28hpcplusbwp30p140ulvt.gds" \
]

# ------------------------------------------------------------------------------
# 2. Helper procs
# ------------------------------------------------------------------------------
proc fatal {msg} {
    puts stderr "\[FATAL\] $msg"
    exit 1
}

proc warn {msg} {
    puts "\[WARN\] $msg"
}

proc check_file_or_die {path what} {
    if {![file exists $path]} {
        fatal "Missing $what: $path"
    }
    puts "  \[OK\] $what: $path"
}

proc check_file_warn {path what} {
    if {![file exists $path]} {
        warn "Missing $what: $path"
        return 0
    }
    puts "  \[OK\] $what: $path"
    return 1
}

proc safe_exec {cmd desc} {
    puts "========== $desc =========="
    set rc [catch {uplevel 1 $cmd} msg]
    if {$rc != 0} {
        warn "$desc failed: $msg"
        return 0
    }
    return 1
}

proc first_dbget_cell {patterns} {
    foreach p $patterns {
        set hits [dbGet head.libCells.name $p]
        if {$hits ne "" && $hits ne "0x0"} {
            return [lindex $hits 0]
        }
    }
    return ""
}

# ------------------------------------------------------------------------------
# 3. Pre-flight checks
# ------------------------------------------------------------------------------
puts "======================================================================"
puts " Innovus ablation/core P&R"
puts "======================================================================"
puts " DESIGN_NAME    : $DESIGN_NAME"
puts " OUT_TAG        : $OUT_TAG"
puts " CORNER_ID      : $CORNER_ID"
puts " NETLIST        : $NETLIST"
puts " SDC            : $SDC"
puts " TECH_LEF       : $TECH_LEF"
puts " RUN_ROOT       : $RUN_ROOT"
puts " DIE_W/H        : $DIE_W / $DIE_H"
puts " CORE_MARGIN    : $CORE_MARGIN"
puts " PLACE_DENSITY  : $PLACE_DENSITY"
puts " QRC_TECH_FILE  : $QRC_TECH_FILE"
puts " CAP_TABLE      : $CAP_TABLE"
puts "======================================================================"

check_file_or_die $NETLIST "gate-level netlist"
check_file_or_die $SDC     "SDC"
check_file_or_die $TECH_LEF "technology LEF"

set LEF_FILES [list $TECH_LEF]
foreach lef $CELL_LEFS {
    check_file_or_die $lef "cell LEF"
    lappend LEF_FILES $lef
}

set TIMING_LIBS [list]
foreach lib $LIB_FILES {
    if {[check_file_warn $lib "timing .lib"]} {
        lappend TIMING_LIBS $lib
    }
}
if {[llength $TIMING_LIBS] == 0} {
    fatal "No timing .lib is available. Check CORNER_ID=$CORNER_ID"
}

set STD_GDS_LIST [list]
foreach gds $STD_GDS_CANDIDATES {
    if {[check_file_warn $gds "stdcell GDS"]} {
        lappend STD_GDS_LIST $gds
    }
}

if {![file exists $GDS_MAP]} {
    warn "GDS map not found: $GDS_MAP ; streamOut GDS will be skipped."
}

# ------------------------------------------------------------------------------
# 4. MMMC
# ------------------------------------------------------------------------------
set MMMC_FILE "${RUN_ROOT}/mmmc_${OUT_TAG}.tcl"
set fp [open $MMMC_FILE w]

puts $fp "create_library_set -name LS_${OUT_TAG} -timing \[list \\"
foreach lib $TIMING_LIBS {
    puts $fp "  $lib \\"
}
puts $fp "\]"
puts $fp ""
puts $fp "create_constraint_mode -name CM_${OUT_TAG} -sdc_files \[list $SDC\]"
puts $fp ""

if {$QRC_TECH_FILE ne "" && [file exists $QRC_TECH_FILE]} {
    puts $fp "create_rc_corner -name RC_${OUT_TAG} -qx_tech_file $QRC_TECH_FILE -T 25"
} elseif {$CAP_TABLE ne "" && [file exists $CAP_TABLE]} {
    puts $fp "create_rc_corner -name RC_${OUT_TAG} -cap_table $CAP_TABLE -T 25"
} else {
    puts $fp "create_rc_corner -name RC_${OUT_TAG} \
        -preRoute_res 1.0 \
        -preRoute_cap 1.0 \
        -postRoute_res {1.0 1.0 1.0} \
        -postRoute_cap {1.0 1.0 1.0} \
        -postRoute_xcap {1.0 1.0 1.0} \
        -T 25"
}
puts $fp ""
puts $fp "create_delay_corner -name DC_${OUT_TAG} -library_set LS_${OUT_TAG} -rc_corner RC_${OUT_TAG}"
puts $fp "create_analysis_view -name AV_${OUT_TAG} -constraint_mode CM_${OUT_TAG} -delay_corner DC_${OUT_TAG}"
puts $fp "set_analysis_view -setup \[list AV_${OUT_TAG}\] -hold \[list AV_${OUT_TAG}\]"
close $fp

puts "========== MMMC file =========="
puts $MMMC_FILE

# ------------------------------------------------------------------------------
# 5. Init design
# ------------------------------------------------------------------------------
set init_lef_file   $LEF_FILES
set init_verilog    $NETLIST
set init_top_cell   $DESIGN_NAME
set init_mmmc_file  $MMMC_FILE
set init_pwr_net    VDD
set init_gnd_net    VSS

init_design
saveDesign "${OUT_DIR}/${DESIGN_NAME}_${OUT_TAG}_init.enc"

# ------------------------------------------------------------------------------
# 6. Global net connect
# ------------------------------------------------------------------------------
globalNetConnect VDD -type pgpin -pin VDD -all
globalNetConnect VSS -type pgpin -pin VSS -all
globalNetConnect VDD -type tiehi -all
globalNetConnect VSS -type tielo -all

# ------------------------------------------------------------------------------
# 7. Floorplan and IO pin placement
# ------------------------------------------------------------------------------
floorPlan -s $DIE_W $DIE_H $CORE_MARGIN $CORE_MARGIN $CORE_MARGIN $CORE_MARGIN

set all_terms [lsort [dbGet top.terms.name]]
set input_terms  {}
set output_terms {}
set other_terms  {}

foreach p $all_terms {
    set term_ptr [dbGet top.terms.name $p -p]
    set dir [dbGet $term_ptr.direction]
    if {$dir eq "input"} {
        lappend input_terms $p
    } elseif {$dir eq "output"} {
        lappend output_terms $p
    } else {
        lappend other_terms $p
    }
}

puts "========== IO pin summary =========="
puts "  Number of top-level terms : [llength $all_terms]"
puts "  Number of input pins      : [llength $input_terms]"
puts "  Number of output pins     : [llength $output_terms]"
puts "  Number of other pins      : [llength $other_terms]"

setPinAssignMode -pinEditInBatch true
if {[llength $input_terms] > 0} {
    safe_exec "editPin -pin \{$input_terms\} -side LEFT -layer M3 -spreadType SIDE -spacing 0.4 -fixedPin 1" "place input pins"
}
if {[llength $output_terms] > 0} {
    safe_exec "editPin -pin \{$output_terms\} -side RIGHT -layer M3 -spreadType SIDE -spacing 0.4 -fixedPin 1" "place output pins"
}
if {[llength $other_terms] > 0} {
    safe_exec "editPin -pin \{$other_terms\} -side TOP -layer M3 -spreadType SIDE -spacing 0.4 -fixedPin 1" "place other pins"
}
setPinAssignMode -pinEditInBatch false

# ------------------------------------------------------------------------------
# 8. Tap/endcap
# ------------------------------------------------------------------------------
set tap_cell [first_dbget_cell [list "*TAP*" "*TAPCELL*"]]
if {$tap_cell ne ""} {
    safe_exec "addWellTap -cell $tap_cell -cellInterval 30 -prefix WELLTAP" "add well taps"
} else {
    warn "No TAP cell found by pattern; skip addWellTap."
}

# Endcap insertion is intentionally skipped in this stable overnight flow.
# In the current Innovus 19.14 + BWP30P140 setup, automatic addEndCap can report
# IMPSP-5106 when row starts already contain pre-placed std-cell instances.
# This is not required for generating routed DEF/netlist/SDF/SPEF/GDS, and skipping
# it avoids a non-fatal ERROR in the log. Re-enable later with explicit boundary
# cells if a clean physical-only DRC/LVS flow requires it.
warn "Skip addEndCap in stable overnight flow to avoid IMPSP-5106."

# ------------------------------------------------------------------------------
# 9. Power planning
# ------------------------------------------------------------------------------
# M8/M9 max width observed around 4.5um in this Innovus/tech LEF setup.
# Use 4um ring width instead of 5um to avoid power planning width violation.
safe_exec {
    addRing \
        -nets {VDD VSS} \
        -type core_rings \
        -follow core \
        -layer {top M9 bottom M9 left M8 right M8} \
        -width {top 4 bottom 4 left 4 right 4} \
        -spacing {top 2 bottom 2 left 2 right 2} \
        -offset {top 5 bottom 5 left 5 right 5}
} "add core power ring"

safe_exec {
    addStripe \
        -nets {VDD VSS} \
        -layer M8 \
        -direction vertical \
        -width 2 \
        -spacing 2 \
        -set_to_set_distance 60 \
        -start_offset 30
} "add vertical power stripes"

safe_exec {
    sroute -connect {corePin floatingStripe} -nets {VDD VSS}
} "special route PG"

# ------------------------------------------------------------------------------
# 10. Placement and pre-CTS optimization
# ------------------------------------------------------------------------------
safe_exec {setPlaceMode -place_global_place_io_pins true} "set place IO mode"
safe_exec {setPlaceMode -place_global_cong_effort high} "set placement congestion effort"
safe_exec "setPlaceMode -place_design_floorplan_mode false" "set floorplan placement mode"

placeDesign
optDesign -preCTS

safe_exec "timeDesign -preCTS -outDir ${RPT_DIR}/timing_prects_setup" "timeDesign preCTS setup"
safe_exec "timeDesign -preCTS -hold -outDir ${RPT_DIR}/timing_prects_hold" "timeDesign preCTS hold"

# ------------------------------------------------------------------------------
# 11. CTS and post-CTS optimization
# ------------------------------------------------------------------------------
safe_exec "create_ccopt_clock_tree_spec -file ${OUT_DIR}/ccopt_${OUT_TAG}.spec" "create ccopt clock tree spec"
if {[file exists "${OUT_DIR}/ccopt_${OUT_TAG}.spec"]} {
    safe_exec "source ${OUT_DIR}/ccopt_${OUT_TAG}.spec" "source ccopt spec"
}

safe_exec {set_ccopt_property target_skew 0.05} "set CTS target skew"
safe_exec {set_ccopt_property target_max_trans 0.20} "set CTS target transition"

ccopt_design

safe_exec "timeDesign -postCTS -outDir ${RPT_DIR}/timing_postcts_setup" "timeDesign postCTS setup"
safe_exec "timeDesign -postCTS -hold -outDir ${RPT_DIR}/timing_postcts_hold" "timeDesign postCTS hold"

# Your pre-layout GLS showed small hold issues; keep postCTS hold fixing enabled.
safe_exec {optDesign -postCTS -hold} "postCTS hold optimization"

# ------------------------------------------------------------------------------
# 12. Routing and post-route optimization
# ------------------------------------------------------------------------------
safe_exec {setNanoRouteMode -routeWithTimingDriven true} "timing-driven route"

# Current flow does not use SI signoff; keep SI-driven route disabled.
safe_exec {setNanoRouteMode -routeWithSiDriven false} "disable SI-driven route"

safe_exec {setNanoRouteMode -drouteFixAntenna true} "antenna fixing"

routeDesign

# Innovus 19.14 requires OCV analysis mode for post-route timing/optimization in
# this flow; otherwise optDesign/timeDesign can fail with IMPOPT-6080/7027.
safe_exec {setAnalysisMode -analysisType onChipVariation -cppr both} "enable OCV for post-route timing"

safe_exec {optDesign -postRoute} "postRoute setup optimization"
safe_exec {optDesign -postRoute -hold} "postRoute hold optimization"

# ------------------------------------------------------------------------------
# 13. Fillers/ties and final PG connect
# ------------------------------------------------------------------------------
set tie_hi [first_dbget_cell [list "*TIEH*" "*TIEHI*" "*TIE1*"]]
set tie_lo [first_dbget_cell [list "*TIEL*" "*TIELO*" "*TIE0*"]]
if {$tie_hi ne "" && $tie_lo ne ""} {
    safe_exec "addTieHiLo -cell \{$tie_hi $tie_lo\}" "add tie high/low cells"
} else {
    warn "Tie cells not found; skip addTieHiLo."
}

set filler_cells [list]
foreach p [list "*DCAP*" "*FILL*"] {
    foreach c [dbGet head.libCells.name $p] {
        if {$c ne "" && $c ne "0x0"} {
            lappend filler_cells $c
        }
    }
}
set filler_cells [lsort -unique $filler_cells]
if {[llength $filler_cells] > 0} {
    safe_exec "addFiller -cell \{$filler_cells\} -prefix FILLER" "add fillers/decaps"
} else {
    warn "No filler/DCAP cells found; skip addFiller."
}

globalNetConnect VDD -type pgpin -pin VDD -all
globalNetConnect VSS -type pgpin -pin VSS -all
safe_exec {sroute -connect {corePin floatingStripe} -nets {VDD VSS}} "final PG reconnect"

# ------------------------------------------------------------------------------
# 14. Extraction and reports
# ------------------------------------------------------------------------------
if {$QRC_TECH_FILE ne "" && [file exists $QRC_TECH_FILE]} {
    safe_exec "setExtractRCMode -engine postRoute -effortLevel medium -qrcTechFile $QRC_TECH_FILE" "set QRC extraction mode"
} else {
    # Without native QRC, this is not signoff.  StarRC/RCXT SPEF should be used
    # later for more credible PT STA.
    safe_exec "setExtractRCMode -engine postRoute -effortLevel low" "set approximate extraction mode"
}

safe_exec {extractRC} "extract approximate RC"

safe_exec "timeDesign -postRoute -outDir ${RPT_DIR}/timing_postroute_setup" "timeDesign postRoute setup"
safe_exec "timeDesign -postRoute -hold -outDir ${RPT_DIR}/timing_postroute_hold" "timeDesign postRoute hold"

safe_exec "report_timing -max_paths 20 > ${RPT_DIR}/timing_setup_top20.rpt" "report setup top20"

# Do not call report_timing for hold in this mode. Innovus can report TCLCMD-1045
# unless timing is already in hold/simultaneous mode. The authoritative hold report
# for this flow is generated by:
#   timeDesign -postRoute -hold -outDir ${RPT_DIR}/timing_postroute_hold
# Check files under ${RPT_DIR}/timing_postroute_hold instead of timing_hold_top20.rpt.
warn "Skip report_timing hold top20; use timing_postroute_hold directory."

safe_exec "report_area > ${RPT_DIR}/area.rpt" "report area"
safe_exec "summaryReport -outdir ${RPT_DIR}/summary -noHtml" "summary report"
safe_exec "report_power > ${RPT_DIR}/power_vectorless.rpt" "report vectorless power"

# ------------------------------------------------------------------------------
# 15. Outputs
# ------------------------------------------------------------------------------
saveDesign "${OUT_DIR}/${DESIGN_NAME}_${OUT_TAG}_routed.enc"

saveNetlist "${OUT_DIR}/${DESIGN_NAME}_${OUT_TAG}_routed.v"
write_sdf "${OUT_DIR}/${DESIGN_NAME}_${OUT_TAG}_routed.sdf"
defOut -floorplan -netlist -routing "${OUT_DIR}/${DESIGN_NAME}_${OUT_TAG}_routed.def"

safe_exec "rcOut -spef ${OUT_DIR}/${DESIGN_NAME}_${OUT_TAG}_innovus_est.spef" "write Innovus-estimated SPEF"

# StreamOut GDS.  First priority for StarRC remains DEF-based extraction using
# star.map_lefdef; GDS is useful for record and possible later GDS-based flow.
if {[file exists $GDS_MAP]} {
    if {[llength $STD_GDS_LIST] > 0} {
        safe_exec "streamOut ${OUT_DIR}/${DESIGN_NAME}_${OUT_TAG}_routed.gds -mapFile $GDS_MAP -merge \{$STD_GDS_LIST\} -libName DesignLib -units 2000 -mode ALL" "streamOut GDS with stdcell merge"
    } else {
        safe_exec "streamOut ${OUT_DIR}/${DESIGN_NAME}_${OUT_TAG}_routed.gds -mapFile $GDS_MAP -libName DesignLib -units 2000 -mode ALL" "streamOut GDS without stdcell merge"
    }
} else {
    warn "Skip streamOut GDS because GDS_MAP is unavailable."
}

# Flow notes
set fp [open "${RPT_DIR}/flow_notes.txt" w]
puts $fp "Design: $DESIGN_NAME"
puts $fp "OUT_TAG: $OUT_TAG"
puts $fp "Corner: $CORNER_ID"
puts $fp "Tech LEF: $TECH_LEF"
puts $fp "GDS map: $GDS_MAP"
puts $fp "Native QRC tech: $QRC_TECH_FILE"
puts $fp "Cap table: $CAP_TABLE"
puts $fp ""
puts $fp "Important notes:"
puts $fp "1. This Innovus run uses mixed-Vt LEF and mixed-Vt .lib."
puts $fp "2. create_rc_corner uses -T, not -temperature."
puts $fp "3. If QRC/capTable is empty, Innovus timing/SPEF is approximate."
puts $fp "4. For more credible post-route STA, use StarRC/RCXT .nxtgrd + star.map_lefdef to extract SPEF and read it in PrimeTime."
puts $fp "5. posit_rf_16x128 is standard-cell synthesized logic, not a hard macro."
puts $fp "6. postCTS/postRoute hold optimization is enabled."
puts $fp "7. routeWithSiDriven is disabled because SI signoff/OCV-SI is not enabled in this flow."
puts $fp "8. Post-route timing/optimization enables OCV to avoid IMPOPT-6080/7027."
puts $fp "9. Power ring width is set to 4um to satisfy current layer width limit."
puts $fp "10. addEndCap is skipped in the stable overnight flow to avoid IMPSP-5106."
puts $fp "11. report_timing hold top20 is skipped; use timeDesign postRoute hold reports."
close $fp

puts "======================================================================"
puts " Innovus P&R completed for $DESIGN_NAME / $OUT_TAG"
puts " Outputs: $OUT_DIR"
puts " Reports: $RPT_DIR"
puts "======================================================================"

exit
