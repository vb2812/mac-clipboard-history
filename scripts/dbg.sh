#!/bin/zsh
# Debug-build automation: scripts/dbg.sh <command>  (toggle|dump|key:down|query:foo|...)
osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('app.clipboard-history.debug', '$1', \$(), true)" >/dev/null
