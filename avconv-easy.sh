#!/bin/bash

red=$(tput setaf 1)
blue=$(tput setaf 4)
gray=$(tput setaf 0)$(tput bold)
green=$(tput setaf 2)
bold=$(tput bold)
reset=$(tput sgr0)

usage() {
	cat <<USAGE
Usage: $0 [options] files
${bold}--quiet${reset}
    Do not print anything
${bold}--verbose${reset}
    Print lots of boring details
${bold}-d,--dir directory${reset}
    Directory to place generated files in; if omitted, the
    current directory is assumed.
${bold}-e,--encoding mp3|ogg|mp3,ogg${reset}
    ${bold}mp3${reset}:     Encode to mp3 using libmp3lame codec
    ${bold}ogg${reset}:     Encode to ogg using libvorbis codec
    ${bold}mp3,ogg${reset}: Encode to both mp3 and ogg
${bold}-m,--metadata key value${reset}
    Set metadata in the audio file (only applies with ${bold}--encoding${reset});
    these values will be applied to ALL converted files
${bold}-p,--prompt${reset}
    Prompt for common metadata values, if not given with ${bold}--metadata${reset}
    (promptable values are "Track", "Artist", "Album", "Year" and "Title")
${bold}--midi${reset}
    Convert a MIDI file to WAV using ${bold}timidity${reset}
${bold}--timidity /path/to/timidity${reset}
    ${bold}timidity${reset} binary to use if not in path (only when ${bold}--midi${reset})
USAGE
}

encoding=
dir=
midi=0
timidity=`which timidity`
files=()
verbose=0
silent=0
declare -A metadata
prompt=0
metadataOptions=

millis() {
	echo $(($(date +%s%N)/1000000))
}

run() {
	debug "\`$@\`"
	eval "$@" 2>&1 | logOutput $1
	return $PIPESTATUS
}

debug() {
	log "debug" "$@"
}
debugCmd() {
	name=$1
	shift
	log "${name}" "$@"
}

info() {
	log "info" "$@"
}

error() {
	log "error" "$@"
}

log() {
	if [ ${silent} -eq 1 ]; then
		return
	fi

	case $1 in
		info)
			echo -n "[${green}$1${reset}]"
			;;
		error)
			echo -n "[${red}$1${reset}]"
			;;
		*)
			if [ ${verbose} -ne 1 ]; then
				return
			fi

			echo -n "[${gray}$1${reset}]"
			;;
	esac

	shift
	echo " $@"
}

logOutput() {
	while read cmdOutput; do
		debugCmd $1 "${cmdOutput}"
	done
}

resolveTarget() {
	basename=`basename "$1"`
	ext=$2
	realTarget="${basename%.*}.${ext}"

	if [ -z "${dir}" ]; then
		echo "${realTarget}"
	else
		echo "${dir}/${realTarget}"
	fi
}

setMetadataOptions() {
	if [ -z "${metadataOptions}" ]; then
		if [ ${prompt} -eq 1 ]; then
			promptableKeys=( "title" "artist" "album" "year" "track" )
			for metaKey in "${promptableKeys[@]}"; do
				metaValue=${metadata[${metaKey}]}
				if [ -z "${metaValue}" ]; then
					read -e -p "Metadata value for \"${metaKey}\": " metaValue
				fi

				if [ -n "${metaValue}" ]; then
					metadataOptions="${metadataOptions} -metadata ${metaKey}=\"${metaValue}\""
				fi
			done
		fi

		for metaKey in "${!metadata[@]}"; do
			metaValue="${metadata["$metaKey"]}"
			metadataOptions="${metadataOptions} -metadata ${metaKey}=\"${metaValue}\"";
		done
	fi
}

encodeMp3() {
	mp3File=$1
	mp3Target=$(resolveTarget "${mp3File}" "mp3")
	setMetadataOptions

	debug "Encoding MP3 (${mp3Target})"
	run ffmpeg -y -i "${mp3File}" -c libmp3lame -b:a 320k ${metadataOptions} "${mp3Target}"
	if [ $? -ne 0 ]; then
		error "Failed to encode MP3"
		exit 1
	fi
	info "Encoded MP3 (${mp3Target})"
}

encodeOgg() {
	oggFile=$1
	oggTarget=$(resolveTarget "${oggFile}" "ogg")
	setMetadataOptions

	debug "Encoding OGG (${oggTarget})"
	run ffmpeg -y -i "${oggFile}" -c libvorbis -aq 4 ${metadataOptions} "${oggTarget}"
	if [ $? -ne 0 ]; then
		error "Failed to encode OGG"
		exit 1
	fi
	info "Encoded OGG (${oggTarget})"
}

getElapsed() {
	if [ $1 -gt 2000 ]; then
		roundedElapsed=$(($1 / 1000))
		echo "${roundedElapsed}.$((($1 - ${roundedElapsed} * 1000) / 10))s"
	else
		echo "$1ms"
	fi
}

while [[ $# > 0 ]]; do
	key="$1"
	shift

	case ${key} in
		-h|--help)
			usage
			exit 0
			;;
		-d|--dir)
			dir="$1"
			shift
			;;
		-e|--encoding)
			encoding="$1"
			shift
			;;
		-m|--metadata)
			key=$1
			metadata+=(["${key,,}"]="$2")
			shift
			shift
			;;
		-p|--prompt)
			prompt=1
			;;
		--midi)
			midi=1
			;;
		--timidity)
			timidity="$1"
			shift
			;;
		-v|--verbose)
			verbose=1
			;;
		-q|--quiet)
			silent=1
			;;
		*)
			files+=("$key")
			;;
	esac
done

# validate args
if [ -z "${encoding}" -a ${midi} -ne 1 ]; then
	error "Either ${bold}--encoding${reset} and/or ${bold}--midi${reset} must be set"
	exit 1
fi
if [ ! -z "${encoding}"  ]; then
	if [ "${encoding}" != "mp3" -a "${encoding}" != "ogg" -a "${encoding}" != "mp3,ogg" ]; then
		error "--encoding must be one of ${bold}mp3${reset}, ${bold}ogg${reset} or ${bold}mp3,ogg${reset} ('${encoding}' was given)"
		exit 1
	fi
fi
if [ ${midi} -eq 1 -a ! -x "${timidity}" ]; then
	error "${bold}timidity${reset} is either not in the path or not executable"
	exit 1
fi

# good to go

# create output directory if necessary
if [ ! -z "${dir}" ]; then
	run mkdir -p "${dir}"
	if [ $? -ne 0 ]; then
		error "Failed to create directory \"${dir}\""
		exit 1
	fi
fi

# convert MIDI to WAV (if necessary), then encode MP3 (if necessary), then encode ogg (if necessary)
aggregateStart=$(millis)
for file in "${files[@]}"; do
	fileStart=$(millis)
	debug "Processing ${file}"

	if [ ! -f "${file}" ]; then
		error "${file} is not a file"
		continue;
	fi

	encodableFile="${file}"
	if [ ${midi} -eq 1 ]; then
		encodableFile=$(resolveTarget "${file}" "wav")
		debug "Converting to WAV (${encodableFile})"
		run timidity -Ow "${file}" -o "${encodableFile}"
		if [ $? -ne 0 ]; then
			error "timidity command failed"
			exit 1
		fi
		info "MIDI -> WAV (${file})"
	fi

	if [ ! -z "${encoding}" ]; then
		case ${encoding} in
			mp3)
				encodeMp3 "${encodableFile}"
				;;
			ogg)
				encodeOgg "${encodableFile}"
				;;
			mp3,ogg)
				encodeMp3 "${encodableFile}"
				encodeOgg "${encodableFile}"
				;;
		esac
	fi

	fileEnd=$(millis)
	fileElapsed=$((${fileEnd} - ${fileStart}))
	debug "Finished processing ${file} [$(getElapsed ${fileElapsed})]"
done

aggregateEnd=$(millis)
aggregateElapsed=$((${aggregateEnd} - ${aggregateStart}))
info "All files processed [$(getElapsed ${aggregateElapsed})]"
