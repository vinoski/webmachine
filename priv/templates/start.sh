#!/bin/sh
cd `dirname $0`
WEBMACHINE_SERVER={{webserver}}
export WEBMACHINE_SERVER
[ {{webserver}} = mochiweb ] && RLDR='-s reloader' || RLDR=
exec erl -pa $PWD/ebin $PWD/deps/*/ebin -boot start_sasl $RLDR -s {{appid}}
