.PHONY: install test

install:
	cp morji.tcl ${PREFIX}/bin/morji

test:
	tclsh8.6 morji.test
	tclsh8.6 test_expect.tcl