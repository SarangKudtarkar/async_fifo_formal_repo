# ------------------------------------------------------------
# JasperGold FPV flow for the asynchronous FIFO
# Run from the repository root.
# ------------------------------------------------------------

clear -all

analyze -sv12 rtl/async_fifo.sv
analyze -sv12 formal/async_fifo_checker.sv
analyze -sv12 formal/async_fifo_bind.sv

elaborate -top async_fifo

# Two independent clocks. Declaring two `clock` commands without a
# -factor / -phase relationship lets JasperGold explore arbitrary
# interleavings of wclk and rclk edges (asynchronous clocks).
# If your release needs it explicit, check `help clock`.
clock wclk
clock rclk

# ERS040: JasperGold only accepts simple reset expressions ("!rst" or
# "rst==1"), not "a || b". A second `reset` command can also replace the
# first, leaving one domain unreset (counterexamples with wcnt=0x1f at
# cycle 1). So: tie the two resets together with an environment
# assumption and declare a single simple reset.
assume -env {wrst_n == rrst_n}
reset -expression {!wrst_n}

set_prove_time_limit 600s

prove -all

report -summary
report

# `exit` errors out (ECD014) when the script is sourced inside the GUI
# session, so it is guarded. It still ends the session in batch mode.
catch {exit}
