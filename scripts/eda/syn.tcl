# ==============================================================================
# syn.tcl
# Project : posit_cim_28nm
# Purpose : Multi-corner non-SPG DC synthesis for cim_top.
#
# Usage example:
#   dc_shell -x "set CORNER tt; set VPE 0p90v; set VOLTAGE 0p90v; set TEMP 25c; set RF_CORNER tt_0p90v_0p90v_25c; set KEEP_HIER 0; set CLK_PERIOD 2.8" -f syn.tcl
#
# Notes:
#   1. This is a non-topographical / non-SPG flow. Do NOT launch dc_shell -topo.
#   2. Mixed-Vt optimization is enabled by putting several Vt libraries in
#      target_library/link_library.
#   3. posit_rf_16x128 is handwritten RTL on this server, but its hierarchy is
#      always preserved and protected from ungrouping.
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. User variables
# ------------------------------------------------------------------------------
if {![info exists DESIGN_NAME]} { set DESIGN_NAME "cim_top" }

if {![info exists CORNER]}  { set CORNER  "tt" }
if {![info exists TEMP]}    { set TEMP    "25c" }
if {![info exists VOLTAGE]} { set VOLTAGE "0p90v" }
if {![info exists VPE]}     { set VPE     $VOLTAGE }

if {![info exists RF_CORNER]} {
    set RF_CORNER "${CORNER}_${VPE}_${VOLTAGE}_${TEMP}"
}

# For synthesis and SDF/GLS. RTL behavioral sim is not a timing signoff.
if {![info exists CLK_PERIOD]} { set CLK_PERIOD 2.8 }

# KEEP_HIER=0: aggressive optimization, except RF hierarchy is kept.
# KEEP_HIER=1: preserve major module boundaries for area/power breakdown.
if {![info exists KEEP_HIER]} { set KEEP_HIER 0 }

# ------------------------------------------------------------------------------
# 2. Paths
# ------------------------------------------------------------------------------
set PROJ_ROOT "/path/to/projects/posit_cim_28nm"
set RTL_ROOT  "${PROJ_ROOT}/rtl"
set SYN_ROOT  "${PROJ_ROOT}/syn"

set DB_ROOT "/path/to/licensed_pdk/tsmcN28/TSMCHOME/digital/Front_End/timing_power_noise/NLDM"

set REPORT_DIR "${SYN_ROOT}/reports_${RF_CORNER}"
set OUTPUT_DIR "${SYN_ROOT}/outputs_${RF_CORNER}"

file mkdir $SYN_ROOT
file mkdir $REPORT_DIR
file mkdir $OUTPUT_DIR

# ------------------------------------------------------------------------------
# 3. Helpers
# ------------------------------------------------------------------------------
proc check_file_or_die {path what} {
    if {![file exists $path]} {
        puts stderr "\[FATAL\] Missing $what: $path"
        exit 1
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
        "hvt"  { return "hvt_180a" }
        "uhvt" { return "uhvt_180b" }
        "lvt"  { return "lvt_180a" }
        "ulvt" { return "ulvt_180a" }
        default { return "${vt}_180a" }
    }
}

proc voltage_token {v} {
    # Match the naming style observed in the new PDK DB files.
    return [string map {"0p90v" "0p9v" "1p00v" "1v"} $v]
}

proc lib_corner_key {corner vpe vce temp} {
    set vpe_t [voltage_token $vpe]
    set vce_t [voltage_token $vce]
    if {$vpe_t eq $vce_t} {
        return "${corner}${vce_t}${temp}"
    } else {
        return "${corner}${vpe_t}${vce_t}${temp}"
    }
}

proc lib_path_for_vt {db_root vt corner_key} {
    set base "tcbn28hpcplusbwp30p140"
    set dir_suffix [vt_dir_suffix $vt]
    if {$vt eq ""} {
        set dir  "${db_root}/${base}${dir_suffix}"
        set file "${base}${corner_key}.db"
    } else {
        set dir  "${db_root}/${base}${dir_suffix}"
        set file "${base}${vt}${corner_key}.db"
    }
    return "${dir}/${file}"
}

# ------------------------------------------------------------------------------
# 4. RTL files
# ------------------------------------------------------------------------------
set RTL_FILES [list \
    "a2c_pd.v" \
    "act_lut_setup.v" \
    "adder_tree.v" \
    "cim_controller.v" \
    "cim_top.v" \
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

puts "========== Pre-flight RTL check =========="
foreach f $RTL_FILES {
    check_file_or_die "${RTL_ROOT}/$f" "RTL $f"
}

# ------------------------------------------------------------------------------
# 5. Library setup: mixed-Vt
# ------------------------------------------------------------------------------
set LIB_KEY [lib_corner_key $CORNER $VPE $VOLTAGE $TEMP]
puts "========== Library selection =========="
puts "  CORNER     = $CORNER"
puts "  VPE        = $VPE"
puts "  VOLTAGE    = $VOLTAGE"
puts "  TEMP       = $TEMP"
puts "  RF_CORNER  = $RF_CORNER"
puts "  LIB_KEY    = $LIB_KEY"
puts "  CLK_PERIOD = $CLK_PERIOD ns"
puts "  KEEP_HIER  = $KEEP_HIER"

# Order matters mildly: include normal/SVT-like lib and leakage/performance Vt variants.
# If some variants are absent at a corner, skip them gracefully.
set VT_LIST [list "" "hvt" "uhvt" "lvt" "ulvt"]
set target_library [list]
foreach vt $VT_LIST {
    set db [lib_path_for_vt $DB_ROOT $vt $LIB_KEY]
    if {[check_file_warn $db "DB vt='$vt'"]} {
        lappend target_library $db
    }
}

if {[llength $target_library] == 0} {
    puts stderr "\[FATAL\] No timing DB found for LIB_KEY=$LIB_KEY. Skipping is safer than guessing."
    exit 2
}

set synthetic_library [list dw_foundation.sldb]
set link_library [concat [list "*"] $target_library $synthetic_library]
set search_path [list . $RTL_ROOT $DB_ROOT]

puts "========== target_library =========="
foreach lib $target_library { puts "  $lib" }

# ------------------------------------------------------------------------------
# 6. Read / elaborate / link
# ------------------------------------------------------------------------------
remove_design -all
file delete -force WORK
define_design_lib WORK -path ./WORK

foreach f $RTL_FILES {
    analyze -format sverilog "${RTL_ROOT}/$f"
}

elaborate $DESIGN_NAME
current_design $DESIGN_NAME
link

check_design > "${REPORT_DIR}/check_design_pre_compile.rpt"

# ------------------------------------------------------------------------------
# 7. Protect handwritten RF hierarchy
# ------------------------------------------------------------------------------
puts "========== RF hierarchy protection =========="
set rf_by_ref [get_cells -hierarchical -filter "ref_name =~ *posit_rf_16x128*" -quiet]
set rf_by_name [get_cells -hierarchical "*posit_rf*" -quiet]
set rf_cells [add_to_collection $rf_by_ref $rf_by_name]

if {[sizeof_collection $rf_cells] > 0} {
    set_dont_touch $rf_cells
    set_ungroup $rf_cells false
    puts "  \[INFO\] Protected [sizeof_collection $rf_cells] RF-related instances from dont_touch/ungroup."
} else {
    puts "  \[WARN\] No RF instance matched *posit_rf_16x128* or *posit_rf*."
}

# ------------------------------------------------------------------------------
# 8. Timing / IO constraints
# ------------------------------------------------------------------------------
puts "========== Timing constraints =========="
set clk_port [get_ports clk_333MHz_i -quiet]
if {[sizeof_collection $clk_port] == 0} {
    puts stderr "\[FATAL\] Cannot find clock port clk_333MHz_i"
    exit 1
}

create_clock -name clk -period $CLK_PERIOD $clk_port

# Slightly less optimistic than pure ideal; tune later after first timing reports.
set_clock_uncertainty [expr {$CLK_PERIOD * 0.05}] [get_clocks clk]
set_clock_transition  [expr {$CLK_PERIOD * 0.03}] [get_clocks clk]

set rst_ports [get_ports rst_n_i -quiet]
set non_data_inputs [add_to_collection $clk_port $rst_ports]
set DATA_INPUTS [remove_from_collection [all_inputs] $non_data_inputs]

if {[sizeof_collection $DATA_INPUTS] > 0} {
    set_input_delay  [expr {$CLK_PERIOD * 0.20}] -clock clk $DATA_INPUTS
    # Use a generic constraint; avoid old LVT-only cell names that may not exist.
    set_max_transition [expr {$CLK_PERIOD * 0.20}] $DATA_INPUTS
}

if {[sizeof_collection [all_outputs]] > 0} {
    set_output_delay [expr {$CLK_PERIOD * 0.20}] -clock clk [all_outputs]
    set_load 0.010 [all_outputs]
}

if {[sizeof_collection $rst_ports] > 0} {
    set_false_path -from $rst_ports
}

# ------------------------------------------------------------------------------
# 9. Hierarchy / optimization policy
# ------------------------------------------------------------------------------
puts "========== Hierarchy policy =========="
if {$KEEP_HIER == 1} {
    puts "  \[INFO\] KEEP_HIER=1: preserve all current hierarchy for module breakdown."
    set_app_var compile_ultra_ungroup_dw false
    set_app_var compile_auto_ungroup_delay_num_cells 0
    set_ungroup [get_designs *] false

    # Explicitly reinforce important modules.
    set target_modules [list \
        "a2c_pd" "act_lut_setup" "adder_tree" "cim_controller" \
        "encode_collect" "exponent_adder" "msa_dcm" \
        "posit_cim_storage_dp" "posit_cim_storage_wrapper" \
        "posit_encoder" "tc_bwc_mf" "weight_encode" "posit_rf_16x128" \
    ]
    foreach mod $target_modules {
        set cells [get_cells -hierarchical -filter "ref_name =~ *${mod}*" -quiet]
        if {[sizeof_collection $cells] > 0} {
            set_ungroup $cells false
            puts "  \[PROTECT\] $mod : [sizeof_collection $cells] instances"
        }
    }
} else {
    puts "  \[INFO\] KEEP_HIER=0: allow aggressive ungrouping except protected RF."
    # Do not call ungroup -all before compile; let compile_ultra decide.
    # RF instances were already protected above.
}

# ------------------------------------------------------------------------------
# 10. Compile
# ------------------------------------------------------------------------------
puts "========== compile_ultra starts =========="
set_leakage_optimization true

if {$KEEP_HIER == 1} {
    compile_ultra -no_autoungroup
} else {
    compile_ultra
}

puts "========== compile_ultra done =========="

# ------------------------------------------------------------------------------
# 11. Reports
# ------------------------------------------------------------------------------
check_design  > "${REPORT_DIR}/check_design_post_compile.rpt"
check_timing  > "${REPORT_DIR}/check_timing.rpt"

report_qor                         > "${REPORT_DIR}/qor.rpt"
report_timing -delay max -max_paths 20 -nworst 1 > "${REPORT_DIR}/timing_setup.rpt"
report_timing -delay min -max_paths 20 -nworst 1 > "${REPORT_DIR}/timing_hold_est.rpt"
report_area                         > "${REPORT_DIR}/area.rpt"
report_area -hierarchy              > "${REPORT_DIR}/area_hier.rpt"
report_power                        > "${REPORT_DIR}/power.rpt"
report_power -hierarchy             > "${REPORT_DIR}/power_hier.rpt"
report_reference -hierarchy         > "${REPORT_DIR}/reference_hier.rpt"
report_constraint -all_violators    > "${REPORT_DIR}/constraints_violators.rpt"

# ------------------------------------------------------------------------------
# 12. Outputs for GLS
# ------------------------------------------------------------------------------
write -format verilog -hierarchy -output "${OUTPUT_DIR}/${DESIGN_NAME}_${RF_CORNER}.v"
write_sdc "${OUTPUT_DIR}/${DESIGN_NAME}_${RF_CORNER}.sdc"
write_sdf "${OUTPUT_DIR}/${DESIGN_NAME}_${RF_CORNER}.sdf"
write -format ddc -hierarchy -output "${OUTPUT_DIR}/${DESIGN_NAME}_${RF_CORNER}.ddc"

puts "========== Corner $RF_CORNER done =========="
puts "Reports: $REPORT_DIR"
puts "Outputs: $OUTPUT_DIR"
exit 0
