# ==============================================================================
# File    : syn_abl_dec.tcl
# Project : posit_cim_28nm
# Purpose : Non-SPG mixed-Vt DC synthesis for cim_top_abl_dec.
# ==============================================================================

# ==============================================================================
# Auto-migrated for posit_cim_28nm on the new server.
# Non-SPG / non-topographical DC flow.
# No Milkyway/TLU+/RF macro .db dependencies.
# Mixed-Vt libraries are selected from:
#   /path/to/licensed_pdk/tsmcN28/TSMCHOME/digital/Front_End/timing_power_noise/NLDM
# posit_rf_16x128 is handwritten RTL and is always protected from ungrouping.
# ==============================================================================


set ABL_TAG "abl_dec"
set DESIGN_NAME "cim_top_abl_dec"

if {![info exists CORNER_ID]} { set CORNER_ID "tt0p9v25c" }
if {![info exists OUT_TAG]}   { set OUT_TAG "${ABL_TAG}_${CORNER_ID}" }
if {![info exists CLK_PERIOD]} { set CLK_PERIOD 2.8 }
if {![info exists KEEP_HIER]}  { set KEEP_HIER 1 }

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

puts "======================================================================"
puts " Ablation synthesis: $ABL_TAG / $DESIGN_NAME"
puts "======================================================================"
puts " CORNER_ID  : $CORNER_ID"
puts " OUT_TAG    : $OUT_TAG"
puts " CLK_PERIOD : $CLK_PERIOD ns"
puts " KEEP_HIER  : $KEEP_HIER"
puts " REPORT_DIR : $REPORT_DIR"
puts " OUTPUT_DIR : $OUTPUT_DIR"
puts "======================================================================"

set RTL_FILES [list \
    "act_lut_setup.v" \
    "adder_tree.v" \
    "cim_controller.v" \
    "cim_top_abl_dec.v" \
    "conv_posit_decoder.v" \
    "encode_collect.v" \
    "exponent_adder.v" \
    "msa_dcm.v" \
    "posit_cim_storage_dp.v" \
    "posit_cim_storage_wrapper.v" \
    "posit_rf_16x128.v" \
    "posit_encoder.v" \
    "tc_bwc_mf.v" \
    "weight_encode.v" \
]

puts "========== RTL pre-flight =========="
foreach f $RTL_FILES {
    check_file_or_die "${RTL_ROOT}/$f" "RTL $f"
}

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
    puts stderr "\[FATAL\] No available timing DB found for CORNER_ID=$CORNER_ID"
    exit 2
}

write_text_file "${REPORT_DIR}/selected_libs.txt" [join $target_library "\n"]

set synthetic_library [list dw_foundation.sldb]
set link_library [concat [list "*"] $target_library $synthetic_library]
set search_path [list . $RTL_ROOT $DB_ROOT]

remove_design -all
file delete -force WORK
define_design_lib WORK -path ./WORK

puts "========== Analyze RTL =========="
foreach f $RTL_FILES {
    analyze -format sverilog "${RTL_ROOT}/$f"
}

puts "========== Elaborate/link =========="
elaborate $DESIGN_NAME
current_design $DESIGN_NAME
link

check_design > "${REPORT_DIR}/check_design_pre_compile.rpt"

puts "========== RF hierarchy protection =========="
set rf_by_ref  [get_cells -hierarchical -filter "ref_name =~ *posit_rf_16x128*" -quiet]
set rf_by_name [get_cells -hierarchical "*posit_rf*" -quiet]
set rf_cells   [add_to_collection $rf_by_ref $rf_by_name]

if {[sizeof_collection $rf_cells] > 0} {
    set_dont_touch $rf_cells
    set_ungroup $rf_cells false
    puts "  \[INFO\] Protected [sizeof_collection $rf_cells] RF-related instances."
} else {
    puts "  \[WARN\] No RF instance matched *posit_rf_16x128* or *posit_rf*."
}

puts "========== Timing constraints =========="
set clk_port [get_ports clk_333MHz_i -quiet]
if {[sizeof_collection $clk_port] == 0} {
    fatal "Cannot find clock port clk_333MHz_i"
}
create_clock -name clk -period $CLK_PERIOD $clk_port

set_clock_uncertainty [expr {$CLK_PERIOD * 0.05}] [get_clocks clk]
set_clock_transition  [expr {$CLK_PERIOD * 0.03}] [get_clocks clk]

set rst_ports [get_ports rst_n_i -quiet]
set non_data_inputs $clk_port
if {[sizeof_collection $rst_ports] > 0} {
    set non_data_inputs [add_to_collection $non_data_inputs $rst_ports]
}
set DATA_INPUTS [remove_from_collection [all_inputs] $non_data_inputs]

if {[sizeof_collection $DATA_INPUTS] > 0} {
    set_input_delay [expr {$CLK_PERIOD * 0.20}] -clock clk $DATA_INPUTS
    set_max_transition [expr {$CLK_PERIOD * 0.20}] $DATA_INPUTS
}

if {[sizeof_collection [all_outputs]] > 0} {
    set_output_delay [expr {$CLK_PERIOD * 0.20}] -clock clk [all_outputs]
    set_load 0.010 [all_outputs]
}

if {[sizeof_collection $rst_ports] > 0} {
    set_false_path -from $rst_ports
}

puts "========== Hierarchy policy =========="
if {$KEEP_HIER == 1} {
    puts "  \[INFO\] KEEP_HIER=1: preserve module boundaries for ablation comparison."
    set_app_var compile_ultra_ungroup_dw false
    set_app_var compile_auto_ungroup_delay_num_cells 0
    set_ungroup [get_designs *] false

    set target_modules [list \
        "conv_posit_decoder" \
        "exponent_adder" \
        "tc_bwc_mf" \
        "weight_encode" \
        "act_lut_setup" \
        "encode_collect" \
        "msa_dcm" \
        "adder_tree" \
        "posit_encoder" \
        "cim_controller" \
        "posit_cim_storage_dp" \
        "posit_cim_storage_wrapper" \
        "posit_rf_16x128" \
    ]

    foreach mod $target_modules {
        set cells [get_cells -hierarchical -filter "ref_name =~ *${mod}*" -quiet]
        if {[sizeof_collection $cells] > 0} {
            set_ungroup $cells false
            puts "  \[PROTECT\] $mod : [sizeof_collection $cells] instances"
        } else {
            puts "  \[WARN\] $mod not found before compile"
        }
    }
} else {
    puts "  \[INFO\] KEEP_HIER=0: allow aggressive compile_ultra optimization except RF."
}

puts "========== compile_ultra starts =========="
set_leakage_optimization true

if {$KEEP_HIER == 1} {
    compile_ultra -no_autoungroup
} else {
    compile_ultra
}

puts "========== compile_ultra done =========="

# Re-apply RF protection defensively after compile.
set rf_by_ref_post  [get_cells -hierarchical -filter "ref_name =~ *posit_rf_16x128*" -quiet]
set rf_by_name_post [get_cells -hierarchical "*posit_rf*" -quiet]
set rf_cells_post   [add_to_collection $rf_by_ref_post $rf_by_name_post]
if {[sizeof_collection $rf_cells_post] > 0} {
    set_dont_touch $rf_cells_post
    set_ungroup $rf_cells_post false
}

puts "========== Write reports =========="
check_design > "${REPORT_DIR}/check_design_post_compile.rpt"
check_timing > "${REPORT_DIR}/check_timing.rpt"
report_qor > "${REPORT_DIR}/qor.rpt"
report_constraint -all_violators > "${REPORT_DIR}/constraints_violators.rpt"
report_timing -delay max -max_paths 20 -nworst 1 > "${REPORT_DIR}/timing_setup.rpt"
report_timing -delay min -max_paths 20 -nworst 1 > "${REPORT_DIR}/timing_hold_est.rpt"
report_area > "${REPORT_DIR}/area.rpt"
report_area -hierarchy > "${REPORT_DIR}/area_hier.rpt"
report_power > "${REPORT_DIR}/power_vectorless.rpt"
report_power -hierarchy > "${REPORT_DIR}/power_hier_vectorless.rpt"
report_reference -hierarchy > "${REPORT_DIR}/reference_hier.rpt"

redirect -file "${REPORT_DIR}/summary.rpt" {
    puts "ABL_TAG=$ABL_TAG"
    puts "DESIGN_NAME=$DESIGN_NAME"
    puts "CORNER_ID=$CORNER_ID"
    puts "OUT_TAG=$OUT_TAG"
    puts "CLK_PERIOD=$CLK_PERIOD"
    puts "KEEP_HIER=$KEEP_HIER"
    puts "VT_LIBS=[join $found_vt_names {,}]"
    report_qor
}

puts "========== Write outputs =========="
write -format verilog -hierarchy -output "${OUTPUT_DIR}/${DESIGN_NAME}_${OUT_TAG}.v"
write_sdc "${OUTPUT_DIR}/${DESIGN_NAME}_${OUT_TAG}.sdc"
write_sdf "${OUTPUT_DIR}/${DESIGN_NAME}_${OUT_TAG}.sdf"
write -format ddc -hierarchy -output "${OUTPUT_DIR}/${DESIGN_NAME}_${OUT_TAG}.ddc"

puts "========== $ABL_TAG @ $OUT_TAG done =========="
puts "Reports: $REPORT_DIR"
puts "Outputs: $OUTPUT_DIR"
exit 0
