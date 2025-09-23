#!/bin/sh

# This script is based fairly heavily off bateau84/openttd's. Thanks, man!

SAVEPATH="/home/container/save"
LOADGAME_CHECK="${loadgame}x"
EXTRA_FLAGS="-c /home/container/openttd.cfg"

# Required to force config to save to /home/container
if [ -f /home/container/.config/openttd.cfg ]; then
        export XDG_DATA_HOME=''
        SAVEPATH="/home/container/.config/save"
        EXTRA_FLAGS="-c /home/container/.config/openttd.cfg"
        echo "WARN: Using legacy configuration directory /home/container/.config/ - it is recommended to migrate to all data inside /home/container/* when possible."
elif [ ! -f /home/container/openttd.cfg ]; then
        # we start the server then kill it quickly to write a config file
        # yes this is a horrific hack but whatever
        echo "INFO: No config file found: generating one"
        timeout 3 /app/openttd -D ${EXTRA_FLAGS} > /dev/null 2>&1
fi

if [ "${LOADGAME_CHECK}" != "x" ]; then
        case ${loadgame} in
                'false')
                        echo "INFO: Creating a new game."
                        exec /app/openttd -D ${EXTRA_FLAGS} -x  -d ${DEBUG}
                        exit 0
                ;;
                'last-autosave')
            		SAVEGAME_TARGET=`ls -rt ${SAVEPATH}/autosave/*.sav | tail -n1`

            		if [ -r "${SAVEGAME_TARGET}" ]; then
                                echo "INFO: Loading from latest autosave - ${SAVEGAME_TARGET}"
                                exec /app/openttd -D ${EXTRA_FLAGS} -g "${SAVEGAME_TARGET}" -x -d ${DEBUG}
                                exit 0
            		else
                		echo "FATAL: ${SAVEGAME_TARGET} not found"
                		exit 1
            		fi
                ;;
                'exit')
            		SAVEGAME_TARGET="${SAVEPATH}/autosave/exit.sav"

            		if [ -r "${SAVEGAME_TARGET}" ]; then
                                echo "INFO: Loading from exit save"
                                exec /app/openttd -D ${EXTRA_FLAGS} -g "${SAVEGAME_TARGET}" -x -d ${DEBUG}
                                exit 0
            		else
                		echo "${SAVEGAME_TARGET} not found - Creating a new game."
                		exec /app/openttd -D ${EXTRA_FLAGS} -x -d ${DEBUG}
                    	        exit 0
            		fi
                ;;
                *)
                        SAVEGAME_TARGET="${SAVEPATH}/${loadgame}"
                        if [ -r "${SAVEGAME_TARGET}" ]; then
                                echo "INFO: Loading ${SAVEGAME_TARGET}"
                                exec /app/openttd -D ${EXTRA_FLAGS} -g "${SAVEGAME_TARGET}" -x -d ${DEBUG}
                                exit 0
                        else
                                echo "FATAL: ${SAVEGAME_TARGET} not found"
                                exit 1
                        fi
                ;;
        esac
else
        echo "INFO: loadgame not set - Creating a new game."
    	exec /app/openttd -D ${EXTRA_FLAGS} -x -d ${DEBUG}
        exit 0
fi