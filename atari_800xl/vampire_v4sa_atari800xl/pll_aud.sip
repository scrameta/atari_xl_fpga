set_global_assignment -entity "pll_aud" -library "lib_pll_aud" -name IP_TOOL_NAME "altera_pll"
set_global_assignment -entity "pll_aud" -library "lib_pll_aud" -name IP_TOOL_VERSION "23.1"
set_global_assignment -entity "pll_aud" -library "lib_pll_aud" -name IP_TOOL_ENV "mwpim"
set_global_assignment -library "lib_pll_aud" -name SPD_FILE [file join $::quartus(sip_path) "pll_aud.spd"]

set_global_assignment -library "lib_pll_aud" -name MISC_FILE [file join $::quartus(sip_path) "pll_aud_sim/pll_aud.vho"]
