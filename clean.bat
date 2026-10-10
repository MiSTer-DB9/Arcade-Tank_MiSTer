@echo off
rem Remove Quartus build output.
rmdir /s /q db
rmdir /s /q incremental_db
rmdir /s /q output_files
rmdir /s /q simulation
rmdir /s /q greybox_tmp
rmdir /s /q hc_output
rmdir /s /q hps_isw_handoff
rmdir /s /q .qsys_edit
del build_id.v
del c5_pin_model_dump.txt
del PLLJ_PLLSPE_INFO.txt
del *.cdf
del /s *.qws
del /s *.ppf
del /s *.ddb
del /s *.bak
pause
