#!/system/bin/sh

PATH=/sbin:/system/sbin:/system/bin:/system/xbin
export PATH

while getopts d op;
do
	case $op in
		d)  dbg_on=1;;
	esac
done
shift $(($OPTIND-1))

scriptname=${0##*/}

debug()
{
	[ $dbg_on ] && echo "Debug: $*"
}

notice()
{
	echo "$*"
	echo "$scriptname: $*" > /dev/kmsg
}

error_and_leave()
{
	local err_msg
	local err_code=$1
	case $err_code in
		1)  err_msg="Error: No response from touch IC";;
		2)  err_msg="Error: Cannot read property $2";;
		3)  err_msg="Error: No matching firmware file found";;
		4)  err_msg="Error: Touch IC is in bootloader mode";;
		5)  err_msg="Error: Touch provides no reflash interface";;
		6)  err_msg="Error: Touch driver is not running";;
	esac
	notice "$err_msg"
	exit $err_code
}

for touch_vendor in $*; do
	debug "searching driver for vendor [$touch_vendor]"
	touch_driver_link=$(ls -l /sys/bus/i2c/drivers/$touch_vendor*/*-*)
	if [ -z "$touch_driver_link" ]; then
		debug "no driver for vendor [$touch_vendor] is running"
		shift 1
	else
		debug "driver for vendor [$touch_vendor] found!!!"
		break
	fi
done

[ -z "$touch_driver_link" ] && error_and_leave 6

touch_path=/sys/devices/${touch_driver_link#*devices/}
panel_path=/sys/devices/virtual/graphics/fb0
debug "sysfs touch path: $touch_path"

[ -f $touch_path/doreflash ] || error_and_leave 5
[ -f $touch_path/poweron ] || error_and_leave 5

debug "wait until driver reports <ready to flash>..."
while true; do
	readiness=$(cat $touch_path/poweron)
	if [ "$readiness" == "1" ]; then
		debug "ready to flash!!!"
		break;
	fi
	sleep 1
	debug "not ready; keep waiting..."
done
unset readiness

device_property=ro.hw.device
hwrev_property=ro.hw.revision
firmware_path=/system/etc/firmware

let dec_cfg_id_boot=0; dec_cfg_id_latest=0;

read_touch_property()
{
	property=""
	debug "retrieving touch property: [$touch_path/$1]"
	property=$(cat $touch_path/$1 2> /dev/null)
	debug "touch property [$1] is: [$property]"
	[ -z "$property" ] && return 1
	return 0
}

read_panel_property()
{
	property=""
	debug "retrieving panel property: [$panel_path/$1]"
	property=$(cat $panel_path/$1 2> /dev/null)
	debug "panel property [$1] is: [$property]"
	[ -z "$property" ] && return 1
	return 0
}

find_latest_config_id()
{
	local fw_mask=$1
	local skip_fields=$2
	local dec max z str_hex i

	str_cfg_id_latest=""

	debug "scanning dir for files matching [$fw_mask]"
	let dec=0; max=0;
	for file in $(ls $fw_mask 2>/dev/null);
	do
		z=$file
		i=0
		while [ ! $i -eq $skip_fields ];
		do
			z=${z#*-}
			i=$((i+1))
		done

		str_hex=${z%%-*};

		let dec=0x$str_hex
		if [ $dec -gt $max ];
		then
			let max=$dec; dec_cfg_id_latest=$dec;
			str_cfg_id_latest=$str_hex
		fi
	done

	[ -z "$str_cfg_id_latest" ] && return 1
	return 0
}

read_touch_property flashprog || error_and_leave 1
bl_mode=$property
debug "bl mode: $bl_mode"

read_touch_property productinfo || error_and_leave 1
touch_product_id=$property
if [ -z "$touch_product_id" ] || [ "$touch_product_id" == "0" ];
then
	debug "touch ic reports invalid product id"
	error_and_leave 3
fi
debug "touch product id: $touch_product_id"

touch_product_id=${touch_product_id%[a-z]}
debug "touch product id without vendor suffix: $touch_product_id"

read_touch_property buildid || error_and_leave 1
str_cfg_id_boot=${property#*-}
let dec_cfg_id_boot=0x$str_cfg_id_boot
debug "touch config id: $str_cfg_id_boot"

product_id=$(getprop $device_property 2> /dev/null)
[ -z "$product_id" ] && error_and_leave 2 $device_property
product_id=${product_id%-*}
debug "product id: $product_id"

hwrev_id=$(getprop $hwrev_property 2> /dev/null)
[ -z "$hwrev_id" ] && error_and_leave 2 $hwrev_property
debug "hw revision: $hwrev_id"

read_panel_property "panel_supplier"
supplier=$property
if [ -z "$supplier" ];
then
	debug "driver does not report panel supplier"
fi
debug "panel supplier: $supplier"

cd $firmware_path

find_best_match()
{
	local hw_mask=$1
	local panel_supplier=$2
	local skip_fields fw_mask

	while [ ! -z "$hw_mask" ]; do
		if [ "$hw_mask" == "-" ]; then
			hw_mask=""
		fi

		if [ ! -z $panel_supplier ];
		then
			skip_fields=3
			fw_mask="$touch_vendor-$panel_supplier-$touch_product_id-*-$product_id$hw_mask.*"
		else
			skip_fields=2
			fw_mask="$touch_vendor-$touch_product_id-*-$product_id$hw_mask.*"
		fi

		find_latest_config_id "$fw_mask" "$skip_fields" && break

		hw_mask=${hw_mask%?}
	done

	[ -z "$str_cfg_id_latest" ] && return 1

	if [ -z $panel_supplier ]; then
		firmware_file=$(ls $touch_vendor-$touch_product_id-$str_cfg_id_latest-*-$product_id$hw_mask.*)
	else
		firmware_file=$(ls $touch_vendor-$panel_supplier-$touch_product_id-$str_cfg_id_latest-*-$product_id$hw_mask.*)
	fi
	notice "Firmware file for upgrade $firmware_file"

	return 0
}

hw_mask="-$hwrev_id"
debug "hw_mask=$hw_mask"

match_not_found=1
if [ ! -z "$supplier" ];
then
	debug "search for best hw revision match with supplier"
	find_best_match "-$hwrev_id" "$supplier"
	match_not_found=$?
fi

if [ "$match_not_found" -ne "0" ];
then
	debug "search for best hw revision match without supplier"
	find_best_match "-$hwrev_id" || error_and_leave 3
fi

if [ $dec_cfg_id_boot -ne $dec_cfg_id_latest ] || [ "$bl_mode" == "1" ];
then
	debug "forcing firmware upgrade"
	echo 1 > $touch_path/forcereflash
	debug "sending reflash command"
	echo $firmware_file > $touch_path/doreflash
	read_touch_property flashprog || error_and_leave 1
	bl_mode=$property

	[ "$bl_mode" == "1" ] && error_and_leave 4

	read_touch_property buildid || error_and_leave 1
	str_cfg_id_new=${property#*-}
	debug "firmware config ids: expected $str_cfg_id_latest, current $str_cfg_id_new"

	notice "Touch firmware config id at boot time $str_cfg_id_boot"
	notice "Touch firmware config id in the file $str_cfg_id_latest"
	notice "Touch firmware config id currently programmed $str_cfg_id_new"

	if [ "$(getprop ro.build.motfactory)" == "1" ];
	then
		echo "Factory build detected! Resetting device after touch firmware upgrade..."
		sleep 1
		reboot
	fi
else
	notice "Touch firmware is up to date"
fi

unset device_property hwrev_property supplier
unset str_cfg_id_boot str_cfg_id_latest str_cfg_id_new
unset dec_cfg_id_boot dec_cfg_id_latest match_not_found
unset hwrev_id product_id touch_product_id scriptname
unset synaptics_link firmware_path touch_path
unset bl_mode dbg_on hw_mask firmware_file property

return 0
