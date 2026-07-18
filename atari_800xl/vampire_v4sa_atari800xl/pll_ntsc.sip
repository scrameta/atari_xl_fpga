set_global_assignment -entity "pll_ntsc" -library "lib_pll_ntsc" -name IP_TOOL_NAME "altera_pll"
set_global_assignment -entity "pll_ntsc" -library "lib_pll_ntsc" -name IP_TOOL_VERSION "23.1"
set_global_assignment -entity "pll_ntsc" -library "lib_pll_ntsc" -name IP_TOOL_ENV "mwpim"
set_global_assignment -library "lib_pll_ntsc" -name SPD_FILE [file join $::quartus(sip_path) "pll_ntsc.spd"]

set_global_assignment -library "lib_pll_ntsc" -name MISC_FILE [file join $::quartus(sip_path) "pll_ntsc_sim/pll_ntsc.vo"]
