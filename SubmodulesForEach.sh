#!/bin/sh

foreach_cmd=$1

git submodule foreach --recursive --quiet pwd | xargs -P10 -I{} bash -c "cd {}; $foreach_cmd || :"