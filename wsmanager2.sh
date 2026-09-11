#!/bin/bash
#This script is a simple manager for all the other bash scripts.
#This way you only need one running websocketd process.
escape_string() {
	    echo "$1" | sed 's/[\\";$`&|]/\\&/g'
}

while read C
do
    cdir=`pwd`
    script=''
    first=''
    args=''
    # does $C have arguments?
    spcs=`echo $C | grep \  | wc -l`
    if [ $spcs -eq 0 ]; then
        first=$C
    else
        # read the first arg to determine what script to run
        IFS=' ' read -a part <<< "$C"
        first=${part[0]}
        #remove the first part of the string, leave all the rest as args to pass to script
	args=$(escape_string "${C#${part[0]}}")
    fi
    # which script to run?
    if [ "$first" == "eval" ]; then
        script='eval_shell.sh'
    elif [ "$first" == "pmsGP" ]; then
        script='pmsGP.sh'
    elif [ "$first" == "logGP" ]; then
        script='logGP.sh'
    elif [ "$first" == "logGP_it" ]; then
        script='logGP_it.sh'
    fi

    if [ ! -z $script ]; then
        #echo "$cdir/$script $args"
	set -o noglob
        eval $cdir/$script $args
        echo "EOF";
	set +o noglob
    else
        echo "I don't understand: $C";
        echo "EOF";
    fi
done

exit 0;
