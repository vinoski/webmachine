ERL          ?= erl
APP          := webmachine
WEBMACHINE_SERVER ?= mochiweb

REPO = ${shell echo `basename "$${PWD}"`}
ARTIFACTSFILE = ${shell echo ${REPO}-`date +%F_%H-%M-%S`.tgz}

.PHONY: deps

all: deps compile

compile: deps
	WEBMACHINE_SERVER=$(WEBMACHINE_SERVER) ./rebar compile

deps:
	@WEBMACHINE_SERVER=$(WEBMACHINE_SERVER) ./rebar get-deps

clean:
	@WEBMACHINE_SERVER=$(WEBMACHINE_SERVER) ./rebar clean

distclean: clean
	@WEBMACHINE_SERVER=$(WEBMACHINE_SERVER) ./rebar delete-deps

edoc:
	@$(ERL) -noshell -run edoc_run application '$(APP)' '"."' '[{preprocess, true},{includes, ["."]}]'
test: all
	@WEBMACHINE_SERVER=$(WEBMACHINE_SERVER) ./rebar skip_deps=true eunit

APPS = kernel stdlib sasl erts ssl tools os_mon runtime_tools crypto inets \
	xmerl webtool snmp public_key mnesia eunit syntax_tools compiler
COMBO_PLT = $(HOME)/.webmachine_dialyzer_plt

check_plt: compile
	dialyzer --check_plt --plt $(COMBO_PLT) --apps $(APPS) ebin

build_plt: compile
	dialyzer --build_plt --output_plt $(COMBO_PLT) --apps $(APPS) ebin

dialyzer: compile
	@echo
	@echo Use "'make check_plt'" to check PLT prior to using this target.
	@echo Use "'make build_plt'" to build PLT prior to using this target.
	@echo
	@sleep 1
	dialyzer -Wno_return --plt $(COMBO_PLT) ebin

cleanplt:
	@echo
	@echo "Are you sure?  It takes about 1/2 hour to re-build."
	@echo Deleting $(COMBO_PLT) in 5 seconds.
	@ech
	sleep 5
	rm $(COMBO_PLT)

verbosetest: all
	@WEBMACHINE_SERVER=$(WEBMACHINE_SERVER) ./rebar -v skip_deps=true eunit

travisupload:
	tar cvfz ${ARTIFACTSFILE} --exclude '*.beam' --exclude '*.erl' test.log .eunit
	travis-artifacts upload --path ${ARTIFACTSFILE}

# Meta-tasks for testing specific backends, does a clean between runs.
# If you want to test with a specific backend repeatedly without the clean,
# use `make test` with WEBMACHINE_SERVER set appropriately.
yaws-test: clean
	@WEBMACHINE_SERVER=yaws ${MAKE} test

cowboy-test: clean
	@WEBMACHINE_SERVER=cowboy ${MAKE} test

mochiweb-test: clean
	@WEBMACHINE_SERVER=mochiweb ${MAKE} test
