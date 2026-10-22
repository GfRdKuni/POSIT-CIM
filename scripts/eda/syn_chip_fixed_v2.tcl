# ==============================================================================
# File    : syn_chip.tcl
# Project : posit_cim_28nm
# Purpose : Non-SPG mixed-Vt DC synthesis for system-level cim_chip.
#
# Recommended location:
#   /path/to/projects/posit_cim_28nm/syn/syn_chip.tcl
#
# Usage through run_chip_syn.sh:
#   cd /path/to/projects/posit_cim_28nm/syn
#   ilaunch ./run_chip_syn.sh
#
# Key policies:
#   - Non-SPG / non-topographical flow.
#   - No Milkyway / TLU+ / RF macro .db dependencies.
#   - Use mixed-Vt standard-cell .db libraries.
#   - Preserve cim_array / cim_top hierarchy where possible.
#   - posit_rf_16x128 is handwritten RTL:
#       * allow DC to synthesize/map its internal logic;
#       * do NOT set_dont_touch on RF instances;
#       * only prevent RF ungrouping.
#   - Use old-server-compatible hierarchical write style:
#       write -format verilog -hierarchy -output ...
#     Do NOT pass [get_designs *] as an extra write argument.
# ==============================================================================

# ------------------------------------------------------------------------------
# 0. Basic setup
# ------------------------------------------------------------------------------
set DESIGN_NAME "cim_chip"

if {![info exists CORNER_ID]}  { set CORNER_ID "tt0p9v25c" }
if {![info exists OUT_TAG]}    { set OUT_TAG "chip_${CORNER_ID}" }
if {![info exists CLK_PERIOD]} { set CLK_PERIOD 2.8 }

if {![info exists VT_LIST]} {
    set VT_LIST [list "" hvt uhvt lvt ulvt]
}

set PROJ_ROOT "/path/to/projects/posit_cim_28nm"
set RTL_ROOT  "${PROJ_ROOT}/rtl"
set SYN_ROOT  "${PROJ_ROOT}/syn"
set DB_ROOT   "/path/to/licensed_pdk/tsmcN28/TSMCHOME/digital/Front_End/timing_power_noise/NLDM"

set REPORT_DIR "${SYN_ROOT}/reports_${OUT_TAG}"
set OUTPUT_DIR "${SYN_ROOT}/outputs_${OUT_TAG}"

file mkdir $SYN_ROOT
file mkdir $REPORT_DIR
file mkdir $OUTPUT_DIR

# ------------------------------------------------------------------------------
# 1. Helper procs
# ------------------------------------------------------------------------------
proc fatal {msg} {
    puts stderr "\[FATAL\] $msg"
    exit 1
}

proc check_file_or_die {path what} {
    if {![file exists $path]} {
        fatal "Missing $what: $path"
    }
    puts "  \[OK\] $what: $path"
}

proc check_file_warn {path what} {
    if {![file exists $path]} {
        puts "  \[WARN\] Missing $what: $path"
        return 0
    }
    puts "  \[OK\] $what: $path"
    return 1
}

proc vt_dir_suffix {vt} {
    switch -- $vt {
        ""     { return "_180a" }
        hvt    { return "hvt_180a" }
        uhvt   { return "uhvt_180b" }
        lvt    { return "lvt_180a" }
        ulvt   { return "ulvt_180a" }
        default { return "${vt}_180a" }
    }
}

proc vt_file_mid {vt} {
    if {$vt eq ""} { return "" }
    return $vt
}

proc lib_path_for_corner {db_root vt corner_id} {
    set base "tcbn28hpcplusbwp30p140"
    set dir_suffix [vt_dir_suffix $vt]
    set mid [vt_file_mid $vt]
    return "${db_root}/${base}${dir_suffix}/${base}${mid}${corner_id}.db"
}

proc write_text_file {path text} {
    set fp [open $path w]
    puts $fp $text
    close $fp
}

proc maybe_report_collection {title coll} {
    puts $title
    if {[sizeof_collection $coll] == 0} {
        puts "  <empty>"
    } else {
        foreach_in_collection x $coll {
            puts "  [get_object_name $x]"
        }
    }
}

puts "======================================================================"
puts " cim_chip synthesis"
puts "======================================================================"
puts " DESIGN_NAME : $DESIGN_NAME"
puts " CORNER_ID   : $CORNER_ID"
puts " OUT_TAG     : $OUT_TAG"
puts " CLK_PERIOD  : $CLK_PERIOD ns"
puts " REPORT_DIR  : $REPORT_DIR"
puts " OUTPUT_DIR  : $OUTPUT_DIR"
puts " RTL_ROOT    : $RTL_ROOT"
puts " DB_ROOT     : $DB_ROOT"
puts "======================================================================"

# ------------------------------------------------------------------------------
# 2. RTL files
# ------------------------------------------------------------------------------
set RTL_FILES [list \
    "a2c_pd.v" \
    "act_lut_setup.v" \
    "adder_tree.v" \
    "cim_controller.v" \
    "encode_collect.v" \
    "exponent_adder.v" \
    "msa_dcm.v" \
    "posit_cim_storage_dp.v" \
    "posit_cim_storage_wrapper.v" \
    "posit_rf_16x128.v" \
    "posit_encoder.v" \
    "tc_bwc_mf.v" \
    "weight_encode.v" \
    "cim_top.v" \
    "cim_array.v" \
    "cim_chip.v" \
]

puts "========== RTL pre-flight =========="
foreach f $RTL_FILES {
    check_file_or_die "${RTL_ROOT}/$f" "RTL $f"
}

# ------------------------------------------------------------------------------
# 3. Mixed-Vt libraries
# ------------------------------------------------------------------------------
puts "========== Mixed-Vt library selection =========="
set target_library [list]
set found_vt_names [list]

foreach vt $VT_LIST {
    set db [lib_path_for_corner $DB_ROOT $vt $CORNER_ID]
    set tag [expr {$vt eq "" ? "base" : $vt}]
    if {[check_file_warn $db "DB $tag"]} {
        lappend target_library $db
        lappend found_vt_names $tag
    }
}

if {[llength $target_library] == 0} {
    fatal "No available timing DB found for CORNER_ID=$CORNER_ID"
}

write_text_file "${REPORT_DIR}/selected_libs.txt" [join $target_library "\n"]

set synthetic_library [list dw_foundation.sldb]
set link_library [concat [list "*"] $target_library $synthetic_library]
set search_path [list . $RTL_ROOT $DB_ROOT]

# ------------------------------------------------------------------------------
# 4. Analyze / elaborate / link
# ------------------------------------------------------------------------------
remove_design -all
file delete -force WORK
define_design_lib WORK -path ./WORK

puts "========== Analyze RTL =========="
foreach f $RTL_FILES {
    analyze -format sverilog -define SYNTHESIS "${RTL_ROOT}/$f"
}

puts "========== Elaborate/link =========="
elaborate $DESIGN_NAME
current_design $DESIGN_NAME
link

check_design > "${REPORT_DIR}/check_design_pre_compile.rpt"

puts "========== Design objects after elaborate/link =========="
redirect -file "${REPORT_DIR}/designs_after_link.rpt" {
    foreach_in_collection d [get_designs *] {
        puts [get_object_name $d]
    }
}

foreach must_have [list cim_chip posit_rf_16x128] {
    set dh [get_designs $must_have -quiet]
    if {[sizeof_collection $dh] == 0} {
        puts "  \[WARN\] Design object '$must_have' not found by exact name after link."
    } else {
        puts "  \[OK\] Design object '$must_have' exists after link."
    }
}

redirect -file "${REPORT_DIR}/cim_like_designs_after_link.rpt" {
    foreach_in_collection d [get_designs *cim* -quiet] {
        puts [get_object_name $d]
    }
}

# ------------------------------------------------------------------------------
# 5. Hierarchy protection
# ------------------------------------------------------------------------------
puts "========== Hierarchy protection =========="

set array_cells [get_cells -hierarchical -filter "ref_name =~ *cim_array*" -quiet]
if {[sizeof_collection $array_cells] > 0} {
    set_ungroup $array_cells false
    puts "  \[INFO\] Preserved [sizeof_collection $array_cells] cim_array instances."
} else {
    puts "  \[WARN\] No cim_array instances found before compile."
}

set core_cells [get_cells -hierarchical -filter "ref_name =~ *cim_top*" -quiet]
if {[sizeof_collection $core_cells] > 0} {
    set_ungroup $core_cells false
    puts "  \[INFO\] Preserved [sizeof_collection $core_cells] cim_top instances."
} else {
    puts "  \[WARN\] No cim_top instances found before compile."
}

# RF is handwritten RTL. Do not set_dont_touch.
set rf_by_ref  [get_cells -hierarchical -filter "ref_name =~ *posit_rf_16x128*" -quiet]
set rf_by_name [get_cells -hierarchical "*posit_rf*" -quiet]
set rf_cells   [add_to_collection $rf_by_ref $rf_by_name]
if {[sizeof_collection $rf_cells] > 0} {
    set_ungroup $rf_cells false
    puts "  \[INFO\] Protected [sizeof_collection $rf_cells] RF-related instances from ungrouping."
} else {
    puts "  \[WARN\] No RF instance matched *posit_rf_16x128* or *posit_rf*."
}

redirect -file "${REPORT_DIR}/hier_cells_before_compile.rpt" {
    maybe_report_collection "cim_array cells:" $array_cells
    maybe_report_collection "cim_top cells:"   $core_cells
    maybe_report_collection "RF cells:"        $rf_cells
}

# ------------------------------------------------------------------------------
# 6. Timing constraints
# ------------------------------------------------------------------------------
puts "========== Timing constraints =========="

set clk_port [get_ports clk_333MHz_i -quiet]
if {[sizeof_collection $clk_port] == 0} {
    fatal "Cannot find clock port clk_333MHz_i"
}

create_clock -name clk -period $CLK_PERIOD $clk_port
set_clock_uncertainty [expr {$CLK_PERIOD * 0.08}] [get_clocks clk]
set_clock_transition  [expr {$CLK_PERIOD * 0.03}] [get_clocks clk]

set rst_ports [get_ports rst_n_i -quiet]

set non_data_inputs $clk_port
if {[sizeof_collection $rst_ports] > 0} {
    set non_data_inputs [add_to_collection $non_data_inputs $rst_ports]
}

set DATA_INPUTS [remove_from_collection [all_inputs] $non_data_inputs]

if {[sizeof_collection $DATA_INPUTS] > 0} {
    set_input_delay -max [expr {$CLK_PERIOD * 0.35}] -clock clk $DATA_INPUTS
    set_input_delay -min 0.0                         -clock clk $DATA_INPUTS
    set_max_transition [expr {$CLK_PERIOD * 0.20}] $DATA_INPUTS
}

if {[sizeof_collection [all_outputs]] > 0} {
    set_output_delay -max [expr {$CLK_PERIOD * 0.20}] -clock clk [all_outputs]
    set_output_delay -min 0.0                         -clock clk [all_outputs]
    set_load 0.010 [all_outputs]
}

if {[sizeof_collection $rst_ports] > 0} {
    set_false_path -from $rst_ports
}

set rf_ctrl_pins [get_pins -hierarchical *posit_rf*/* -quiet]
if {[sizeof_collection $rf_ctrl_pins] > 0} {
    group_path -name RF_RELATED_PATHS -to $rf_ctrl_pins -weight 3.0
}

redirect -file "${REPORT_DIR}/constraints_summary.rpt" {
    report_clock
    report_port -verbose [all_inputs]
    report_port -verbose [all_outputs]
}

# ------------------------------------------------------------------------------
# 7. Compile
# ------------------------------------------------------------------------------
puts "========== compile_ultra starts =========="
set_leakage_optimization true
compile_ultra
puts "========== compile_ultra done =========="

# Re-apply hierarchy protections defensively after compile.
set array_cells_post [get_cells -hierarchical -filter "ref_name =~ *cim_array*" -quiet]
if {[sizeof_collection $array_cells_post] > 0} {
    set_ungroup $array_cells_post false
    puts "  \[INFO\] Re-preserved [sizeof_collection $array_cells_post] cim_array instances."
} else {
    puts "  \[WARN\] No cim_array instances found after compile."
}

set core_cells_post [get_cells -hierarchical -filter "ref_name =~ *cim_top*" -quiet]
if {[sizeof_collection $core_cells_post] > 0} {
    set_ungroup $core_cells_post false
    puts "  \[INFO\] Re-preserved [sizeof_collection $core_cells_post] cim_top instances."
} else {
    puts "  \[WARN\] No cim_top instances found after compile."
}

set rf_by_ref_post  [get_cells -hierarchical -filter "ref_name =~ *posit_rf_16x128*" -quiet]
set rf_by_name_post [get_cells -hierarchical "*posit_rf*" -quiet]
set rf_cells_post   [add_to_collection $rf_by_ref_post $rf_by_name_post]
if {[sizeof_collection $rf_cells_post] > 0} {
    set_ungroup $rf_cells_post false
    puts "  \[INFO\] Re-protected [sizeof_collection $rf_cells_post] RF-related instances from ungrouping."
}

current_design $DESIGN_NAME
link

puts "========== Design objects after compile =========="
redirect -file "${REPORT_DIR}/designs_after_compile.rpt" {
    foreach_in_collection d [get_designs *] {
        puts [get_object_name $d]
    }
}
redirect -file "${REPORT_DIR}/cim_like_designs_after_compile.rpt" {
    foreach_in_collection d [get_designs *cim* -quiet] {
        puts [get_object_name $d]
    }
}
redirect -file "${REPORT_DIR}/hier_cells_after_compile.rpt" {
    maybe_report_collection "cim_array cells:" $array_cells_post
    maybe_report_collection "cim_top cells:"   $core_cells_post
    maybe_report_collection "RF cells:"        $rf_cells_post
}

# ------------------------------------------------------------------------------
# 8. Reports
# ------------------------------------------------------------------------------
puts "========== Write reports =========="
check_design > "${REPORT_DIR}/check_design_post_compile.rpt"
check_timing > "${REPORT_DIR}/check_timing.rpt"
report_qor > "${REPORT_DIR}/qor.rpt"
report_constraint -all_violators > "${REPORT_DIR}/constraints_violators.rpt"
report_timing -delay max -max_paths 30 -nworst 1 > "${REPORT_DIR}/timing_setup.rpt"
report_timing -delay min -max_paths 30 -nworst 1 > "${REPORT_DIR}/timing_hold_est.rpt"
report_area > "${REPORT_DIR}/area.rpt"
report_area -hierarchy > "${REPORT_DIR}/area_hier.rpt"
report_power > "${REPORT_DIR}/power_vectorless.rpt"
report_power -hierarchy > "${REPORT_DIR}/power_hier_vectorless.rpt"
report_reference -hierarchy > "${REPORT_DIR}/reference_hier.rpt"

redirect -file "${REPORT_DIR}/summary.rpt" {
    puts "DESIGN_NAME=$DESIGN_NAME"
    puts "CORNER_ID=$CORNER_ID"
    puts "OUT_TAG=$OUT_TAG"
    puts "CLK_PERIOD=$CLK_PERIOD"
    puts "VT_LIBS=[join $found_vt_names {,}]"
    report_qor
}

# ------------------------------------------------------------------------------
# 9. Outputs
# ------------------------------------------------------------------------------
puts "========== Write outputs =========="
current_design $DESIGN_NAME
link

# Delete old outputs first so a failed write cannot silently leave stale files.
file delete -force "${OUTPUT_DIR}/${DESIGN_NAME}_${OUT_TAG}.v"
file delete -force "${OUTPUT_DIR}/${DESIGN_NAME}_${OUT_TAG}.sdc"
file delete -force "${OUTPUT_DIR}/${DESIGN_NAME}_${OUT_TAG}.sdf"
file delete -force "${OUTPUT_DIR}/${DESIGN_NAME}_${OUT_TAG}.ddc"

# Use old-server-compatible hierarchical write style.
write -format verilog -hierarchy -output "${OUTPUT_DIR}/${DESIGN_NAME}_${OUT_TAG}.v"
write_sdc "${OUTPUT_DIR}/${DESIGN_NAME}_${OUT_TAG}.sdc"
write_sdf "${OUTPUT_DIR}/${DESIGN_NAME}_${OUT_TAG}.sdf"
write -format ddc -hierarchy -output "${OUTPUT_DIR}/${DESIGN_NAME}_${OUT_TAG}.ddc"

puts "========== Post-write file sanity =========="
if {![file exists "${OUTPUT_DIR}/${DESIGN_NAME}_${OUT_TAG}.v"]} {
    fatal "Failed to write Verilog netlist."
}
if {![file exists "${OUTPUT_DIR}/${DESIGN_NAME}_${OUT_TAG}.sdc"]} {
    fatal "Failed to write SDC."
}
if {![file exists "${OUTPUT_DIR}/${DESIGN_NAME}_${OUT_TAG}.sdf"]} {
    fatal "Failed to write SDF."
}
if {![file exists "${OUTPUT_DIR}/${DESIGN_NAME}_${OUT_TAG}.ddc"]} {
    fatal "Failed to write DDC."
}

redirect -file "${REPORT_DIR}/write_sanity.rpt" {
    puts "Output netlist:"
    puts "  ${OUTPUT_DIR}/${DESIGN_NAME}_${OUT_TAG}.v"
    puts ""
    puts "Expected GLS sanity from shell:"
    puts "  grep -n '^module cim_chip'  ${OUTPUT_DIR}/${DESIGN_NAME}_${OUT_TAG}.v | head"
    puts "  grep -n '^module cim_array' ${OUTPUT_DIR}/${DESIGN_NAME}_${OUT_TAG}.v | head"
    puts "  grep -n '^module cim_top'   ${OUTPUT_DIR}/${DESIGN_NAME}_${OUT_TAG}.v | head"
    puts "  grep -n '\\*\\*SEQGEN\\*\\*\\|GTECH' ${OUTPUT_DIR}/${DESIGN_NAME}_${OUT_TAG}.v | head"
    puts ""
    puts "Design objects after compile:"
    foreach_in_collection d [get_designs *] {
        puts "  [get_object_name $d]"
    }
}

puts "========== cim_chip @ $OUT_TAG done =========="
puts "Reports: $REPORT_DIR"
puts "Outputs: $OUTPUT_DIR"
exit 0
