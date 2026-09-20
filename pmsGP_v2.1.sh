#!/bin/bash

umask 000

alias rm='rm -f'
alias cp='cp -f'
alias mv='mv -f'

trap "exit 0" SIGINT SIGTERM;

escape_string() {
 echo "$1" | sed 's/["\\|;]/\\&/g'
}

[ "$#" -ne 8 ] && echo "The number of parameter is not equal to 8.  Stop here." && exit 0;

export LANG=C           # for GUI mode use
hostlist="127.0.0.1";     # debug use => dynamic generate all hosts read /etc/hosts on remote server
runflag=1;
NOW=`date +%Y%m%d`;
timeStamp=`date +'%Y_%m_%d_%H_%M_%S'`;
dailydir=`date +'%Y%m%d'`;
backupdir="/ws/old/$dailydir"
tempfile="/ws/tempfile";
sshfile="";
result=0;

cp -f /dev/null $tempfile;
chmod 777 $tempfile;

log_table="/ws/log_file";
[ -f "$log_table" ] || cp -f /dev/null "$log_table";

seed_table="/ws/geu_file";
[ -f "$seed_table" ] || echo "pass:wtftfx" > $seed_table;

seeds=$(cat $seed_table | cut -d '|' -f1 | awk '!x[$0]++' | tr ' ' '\n');

iType=$1;
iMode=$2;

iUser=$3;
iPwd=$4;

p1=$5;
p2=$6;
p3=$7;
p4=$8;

if [ ! -z "$iMode" -a "$iMode" != " " ]; then

case "$iMode" in

loginQuery)

dt=$(date +%Y-%m-%d"_"%T);

filename="/ws/gen_file";
[ -f "$filename" ] || cp -f /dev/null "$filename";

filename2="/ws/ges_file";
[ -f "$filename2" ] || echo "90|Y|${dt}" > "$filename2";

expire_num=$(awk -F'|' '{print $1}' /ws/ges_file|xargs);

#stmt="^${iUser}|.*${iPwd}.*Y.*";
stmt="^${iUser}|${iPwd}|.*Y.*";

result=`grep -e "${stmt}" ${filename} | cut -d '|' -f3 | awk '!x[$0]++'`;

new=$(date +%Y-%m-%d);
old=$(grep -e "${stmt}" ${filename} | cut -d '|' -f5 | awk '!x[$0]++'| awk -F'_' '{print $1}');
diff=$(echo $(($(($(date -d "$new" "+%s") - $(date -d "$old" "+%s"))) / 86400)));

if [ "$diff" -gt "$expire_num" ]; then
 echo "-1|EXP";
else

if [ ! -z "$result" -a "$result" != " " ]; then
 msg="[OK] loginID: [${iUser}] Check LoginID Password Profile OK";
else
 msg="[Failed]  loginID: [${iUser}] Check LoginID Password Profile Failed";
fi

echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table};

[ ! -z "$result" -a "$result" != " " ] && echo "1|${result}" || echo "0|USER";

fi

#echo "EOF";
exit $?;
;;

statusQuery)

filename="/ws/chk_file";

[ -f "$filename" ] || cp -f /dev/null "$filename";

result=`egrep -i "OK" ${filename} | wc -l`;

if [ "$result" -gt 0 ]; then
 msg="[OK] loginID: [${iUser}] Check status OK";
else
 msg="[Failed] loginID: [${iUser}] Check status Failed";
fi

echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table};
echo "$result";

#echo "EOF";
exit $?;
;;

pmsQuery)

filename_auth="/ws/gep_file"
filename_pms="/ws/pms_file"
[ -f "$filename_auth" ] || cp -f /dev/null "$filename_auth"
[ -f "$filename_pms" ] || cp -f /dev/null "$filename_pms"

plain=$(mktemp /tmp/pms_plain.XXXXXX) || { echo "ERROR|cannot create temp file"; exit 1; }
err=$(mktemp /tmp/pms_err.XXXXXX) || { rm -f "$plain"; echo "ERROR|cannot create temp file"; exit 1; }
trap 'rm -f "$plain" "$err"' EXIT

if ! openssl enc -aes-256-cbc -d -pbkdf2 -a -salt -pass "$seeds" -in "$filename_pms" -out "$plain" 2>"$err"; then
    echo "ERROR|PMS_DECRYPT_FAILED"
    cat "$err" >&2
    msg="[Failed] loginID: [${iUser}] Query Current Password Profile - decrypt failed"
    echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table}
    exit 1
fi

tr -d '\r' < "$plain" > "${plain}.txt" && mv -f "${plain}.txt" "$plain"
if [ ! -s "$plain" ] || ! awk -F'|' 'NF!=3 || $1=="" {bad=1} END{exit bad?1:0}' "$plain"; then
    echo "ERROR|PMS_PLAINTEXT_INVALID"
    msg="[Failed] loginID: [${iUser}] Query Current Password Profile - invalid plaintext"
    echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table}
    exit 1
fi

query="$p1"
[ "$query" = "@" ] && query=""
[ "$query" = "*" ] && query=""
include_root=0
[ "$p2" = "Y" ] && include_root=1

out=$(mktemp /tmp/pms_query.XXXXXX) || { echo "ERROR|cannot create temp file"; exit 1; }
trap 'rm -f "$plain" "$err" "$out"' EXIT

if [ "${iType}" = "ADMIN" ]; then
    awk -F'|' -v q="$query" -v root="$include_root" '
        (!root && $1=="root") {next}
        (q=="" || index($0,q)>0) && !seen[$0]++ {print}
    ' "$plain" | nl -w1 -s '|' > "$out"
else
    allow=$(mktemp /tmp/pms_allow.XXXXXX) || { echo "ERROR|cannot create temp file"; exit 1; }
    trap 'rm -f "$plain" "$err" "$out" "$allow"' EXIT
    awk -F'[|@]' -v u="$iUser" '$1==u && $3=="Y" {print $2}' "$filename_auth" | awk '!seen[$0]++' > "$allow"
    awk -F'|' -v q="$query" -v root="$include_root" '
        NR==FNR {allow[$1]=1; next}
        !allow[$1] {next}
        (!root && $1=="root") {next}
        (q=="" || index($0,q)>0) && !seen[$0]++ {print}
    ' "$allow" "$plain" | nl -w1 -s '|' > "$out"
fi

cat "$out"
if [ -s "$out" ]; then
    msg="[OK] loginID: [${iUser}] Query Current Password Profile"
else
    msg="[OK] loginID: [${iUser}] Query Current Password Profile - no rows"
fi
echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table}
exit 0
;;

usersQuery)

filename="/ws/geo_file";

[ -f "$filename" ] || cp -f /dev/null "$filename";

if [[ "${iType}" != "ADMIN" ]] && [[ "${iType}" != "ADMINA" ]] && [[ "${iType}" != "ADMINB" ]] && [[ "${iType}" != "GOD" ]]; then
stmt="^${iUser}.*Y";
else
stmt=".*Y.*";
fi

grep -i "${stmt}" ${filename} | cut -d '|' -f1,2 | awk '!x[$0]++' | tr ' ' '\n';

if [[ $? != 0 ]]; then
 msg="[Failed]  LoginID: [${iUser}] Query System Account Profile Failed";
else
 msg="[OK] LoginID: [${iUser}] Query System Account Profile OK";
fi
echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table};

#echo "EOF";
exit $?;
;;

logQuery)

filename="/ws/log_file";

[ -f "$filename" ] || cp -f /dev/null "$filename";

#str1=`echo $p1 | tr '@' '*'`;
str1=`echo $p1 | sed 's/@//g' | sed 's/*//g' `;

#stmt="^.*${str1}|.*";
stmt="^${str1}";
from=$p2;
to=`date -d "${p3} + 1 days"  +%Y/%m/%d`;

if [[ "${iType}" != "ADMIN" ]] && [[ "${iType}" != "ADMINA" ]] && [[ "${iType}" != "ADMINB" ]] && [[ "${iType}" != "GOD" ]]; then
stmt2="^${iUser}.*Y";
else
stmt2=".*";
fi

grep -i "${stmt2}" ${filename} | egrep -i "${stmt}" | awk -F '|' '$5>=from&&$5<=to' from="${from}" to="${to}" | sort -r -t '|' -k5 -d | nl -w1 -s '|'

#echo $to"-"$from
#egrep -i "${stmt}" "${filename}" | awk -F '|' '$5>=from&&$5<=to' from="${from}" to="${to}" | nl -w1 -s '|'

if [[ $? != 0 ]]; then
 msg="[Failed]  loginID: [${iUser}] Query System log Profile Failed";
else
 msg="[OK] loginID: [${iUser}] Query System log Profile OK";
fi
echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table};

#echo "EOF";
exit $?;
;;

pms2Query)
filename="/ws/pms_file"
[ -f "$filename" ] || cp -f /dev/null "$filename"

plain=$(mktemp /tmp/pms2_plain.XXXXXX) || { echo "ERROR|cannot create temp file"; exit 1; }
err=$(mktemp /tmp/pms2_err.XXXXXX) || { rm -f "$plain"; echo "ERROR|cannot create temp file"; exit 1; }
trap 'rm -f "$plain" "$err"' EXIT

if ! openssl enc -aes-256-cbc -d -pbkdf2 -a -salt -pass "$seeds" -in "$filename" -out "$plain" 2>"$err"; then
    echo "ERROR|PMS_DECRYPT_FAILED"
    cat "$err" >&2
    msg="[Failed] loginID: [${iUser}] Query Current Password Profile - decrypt failed"
    echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table}
    exit 1
fi

tr -d '\r' < "$plain" > "${plain}.txt" && mv -f "${plain}.txt" "$plain"
if [ ! -s "$plain" ] || ! awk -F'|' 'NF!=3 || $1=="" {bad=1} END{exit bad?1:0}' "$plain"; then
    echo "ERROR|PMS_PLAINTEXT_INVALID"
    msg="[Failed] loginID: [${iUser}] Query Current Password Profile - invalid plaintext"
    echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table}
    exit 1
fi

variable="$p1"
if [ "$variable" = "all" ]; then
    awk -F'|' '!seen[$0]++ {
        pwd=$2;
        pre=substr(pwd,1,length(pwd)-4);
        suf=substr(pwd,5);
        print $1"|"pwd"|"pre"|"suf"|"$3
    }' "$plain" | nl -w1 -s '|'
else
    wanted=$(mktemp /tmp/pms2_wanted.XXXXXX) || { echo "ERROR|cannot create temp file"; exit 1; }
    trap 'rm -f "$plain" "$err" "$wanted"' EXIT
    printf '%s\n' "$variable" | tr ',' '\n' | awk 'NF && !seen[$0]++' > "$wanted"
    awk -F'|' '
        NR==FNR {want[$1]=1; next}
        want[$1] && !seen[$0]++ {
            pwd=$2;
            pre=substr(pwd,1,length(pwd)-4);
            suf=substr(pwd,5);
            print $1"|"pwd"|"pre"|"suf"|"$3
        }
    ' "$wanted" "$plain" | nl -w1 -s '|'
fi

rc=$?
if [ "$rc" -ne 0 ]; then
    msg="[Failed] loginID: [${iUser}] Query Current Password Profile"
else
    msg="[OK] loginID: [${iUser}] Query Current Password Profile"
fi
echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table}
exit "$rc"
;;

gemQuery)

filename="/ws/gem_file";

[ -f "$filename" ] || cp -f /dev/null "$filename";

cat $filename | awk '!x[$0]++' | nl -w1 -s '|';

if [[ $? != 0 ]]; then
 msg="[Failed] loginID: [${iUser}] Query HostIP Profile Failed";
else
 msg="[OK] loginID: [${iUser}] Query HostIP Profile OK";
fi
echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table};

#echo "EOF";
exit $?;
;;

genQuery)

filename="/ws/gen_file";

[ -f "$filename" ] || cp -f /dev/null "$filename";

str1=`echo $p1 | tr '@' '*'`;

if [ "${iType}" != "ADMIN" ]; then
stmt="^.*${iUser}|.*";
else
stmt="^.*${str1}.*";
fi

grep -i "${stmt}" $filename | awk '!x[$0]++' | nl -w1 -s '|';

if [[ $? != 0 ]]; then
 msg="[Failed]  loginID: [${iUser}] Query User Login Profile Failed";
else
 msg="[OK] loginID: [${iUser}] Query User Login Profile OK";
fi
echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table};

#echo "EOF";
exit $?;
;;


geoQuery)

filename="/ws/geo_file";

[ -f "$filename" ] || cp -f /dev/null "$filename";

#stmt="^.*";

#str1=`echo $p1 | tr '@' '*'`;

#if [ "${iType}" != "ADMIN" ]; then
#stmt="^${iUser}.*";
#else
stmt="^.*";
#fi

grep -i "${stmt}" $filename | awk '!x[$0]++' | nl -w1 -s '|';

if [[ $? != 0 ]]; then
 msg="[Failed]  loginID: [${iUser}] Query OS Account Profile Failed";
else
 msg="[OK] loginID: [${iUser}] Query OS Account Profile OK";
fi
echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table};

#echo "EOF";
exit $?;
;;

gepQuery)

filename1="/ws/f1.txt";
filename2="/ws/gep_file";
tempfile="/ws/tempfile";
tempfile2="/ws/tempfile2";

cp -f /dev/null $filename1;
cp -f /dev/null $tempfile;
cp -f /dev/null $tempfile2;

str1=`echo $p1 | tr '@' '*'`;

if [ "${iType}" != "ADMIN" ]; then
stmt=".*${iUser}.*";
else
stmt=".*${str1}.*";
fi

#tbl1=`grep '^.*Y' /ws/gen_file | cut -d '|' -f1 | awk '!x[$0]++' | xargs | sed -e 's/ /,/g'`
#tbl2=`grep '^.*Y' /ws/geo_file | cut -d '|' -f1 | awk '!x[$0]++' | xargs | sed -e 's/ /,/g'`;

tbl1=`egrep "^.*Y" /ws/gen_file | cut -d '|' -f1 | awk '!x[$0]++' | xargs | sed -e 's/ /,/g'`
tbl2=`egrep "^.*Y" /ws/geo_file | cut -d '|' -f1 | awk '!x[$0]++' | xargs | sed -e 's/ /,/g'`;




filterusers=`egrep "^.*Y" /ws/gen_file | awk -F '|' '{print "^"$1}' | awk '!x[$0]++' | xargs | sed -e 's/ /|/g'`;
filterusers="'"${filterusers}"'";

#echo $stmt
#echo $tbl1
#echo $tbl2
#echo $filterusers
#exit 0;

# cross_jon_table="printf \"%s\n\""" "\{$tbl1"}\"|\"{"$tbl2"} | grep -E "${filterusers}" | sort | uniq > $filename1";

lsign1="";
rsign1="";
lsign2="";
rsign2="";

lnum=`echo $tbl1 | tr ',' '\n' | wc -l`;
rnum=`echo $tbl2 | tr ',' '\n' | wc -l`;

if [ "$lnum" -gt 1 ]; then
lsign1="{";
rsign1="}";
fi

if [ "$rnum" -gt 1 ]; then
lsign2="{";
rsign2="}";
fi

cross_jon_table="printf \"%s\n\" ""$lsign1$tbl1$rsign1"\"\|\""$lsign2$tbl2$rsign2 | grep -E "${filterusers}" | sort | uniq > $filename1";

eval $cross_jon_table;

#join -e "N" -o auto -a 1 -a 2 -t '@' -1 1 -2 1 <(sort -k1,1 $filename1) <( sort  -t '@' -k1,1  $filename2 ) | grep -E ${filterusers} | tee $tempfile | tr '@' '|' | egrep "${stmt}" | nl -w1 -s '|';

join -e "N" -o auto -a 1 -a 2 -t '@' -1 1 -2 1 <(sort -k1,1 $filename1) <( sort  -t '@' -k1,1  $filename2 ) > $tempfile ;

cat $tempfile | tr '@' '|' | egrep "${stmt}" | nl -w1 -s '|';

cp -f $tempfile $filename2 &> /dev/null;

chmod 777 $filename2 &> /dev/null;

if [[ $? != 0 ]]; then
 msg="[Failed] loginID: [${iUser}] Query Authorized Profile OK";
else
 msg="[OK] loginID: [${iUser}] Query Authorized Profile Failed";
fi
echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table};

#echo "EOF";
exit $?;
;;

pexQuery)

filename="/ws/gep_file";

[ -f "$filename" ] || cp -f /dev/null "$filename";

stmt="^${iUser}.*Y";

result=$(cat $filename | egrep -i "$stmt" | wc -l);

if [ "$result" -eq 0 ]; then
   exit $?;
fi

if [ "$iType" == "ADMIN" ]; then
filter="^.*|.*"
else
filter=`egrep "${stmt}" ${filename} | cut -d '|' -f2 | cut -d '@' -f1 | awk '!x[$0]++' | awk '{print "^"$0}' | xargs | sed -e 's/ /|/g'`;
fi

filterusers=`egrep "${stmt}" ${filename} | cut -d '|' -f2 | cut -d '@' -f1 | awk '!x[$0]++' | xargs | sed -e 's/ /|/g'`;
#filterusers=`egrep "${stmt}" ${filename} | cut -d '|' -f2 | cut -d '@' -f1 | awk '!x[$0]++' | awk '{print "^"$0}' | xargs | sed -e 's/ /|/g'`;

filename1="/ws/pms_file";
filename2="/ws/gem_file";

str1=`echo "$p1" | tr '@' '*'`;
#stmt1="^.*${str1}|.*";
stmt1=".*${str1}.*";

tbl2=`cat $filename1 | openssl enc -aes-256-cbc -d -pbkdf2 -a -salt -pass $seeds | grep -Ew "$filter" | awk -F '|' '{print $1"#"$2"#"$3}' | awk '!x[$0]++' | xargs | sed -e 's/ /,/g'`
tbl1=`grep -E "^.*Y" $filename2 | awk -F '|' '{print $1"#"$2"#"$3}' | awk '!x[$0]++' | xargs | sed -e 's/ /,/g'`;

lsign1="";
rsign1="";
lsign2="";
rsign2="";

lnum=`echo $tbl1 | tr ',' '\n' | wc -l`;
rnum=`echo $tbl2 | tr ',' '\n' | wc -l`;

if [ "$lnum" -gt 1 ]; then
lsign1="{";
rsign1="}";
fi

if [ "$rnum" -gt 1 ]; then
lsign2="{";
rsign2="}";
fi

cross_jon_table="printf \"%s\n\" ""$lsign1$tbl1$rsign1"\"\|\""$lsign2$tbl2$rsign2";

tbl=`eval $cross_jon_table`;

data=`echo $tbl | sed -e "s/#/|/g"`;



if [ "${iType}" != "ADMIN" ]; then

if [ "${p2}" != "Y" ]; then
 echo $data | tr " " "\n" | nl -w1 -s '|' | grep -E "${filterusers}" | grep "${stmt1}" | grep -v "root" ;
else
 echo $data | tr " " "\n" | nl -w1 -s '|' | grep -E "${filterusers}" | grep "${stmt1}";
fi

else

if [ "${p2}" != "Y" ]; then
 echo $data | tr " " "\n" | nl -w1 -s '|' | grep "${stmt1}" | grep -v "root";
else
 echo $data | tr " " "\n" | nl -w1 -s '|' | grep "${stmt1}";
fi

fi

#echo $data | tr " " "\n" | grep -E '${filterusers}' | grep -E '${stmt}';

if [[ $? != 0 ]]; then
 msg="[Failed] loginID: [${iUser}] Query Advanced Password Profile";
else
 msg="[OK] loginID: [${iUser}] Query Advanced Password Profile";
fi
echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table};

#echo "EOF";
exit $?;
;;
# geqQuery)
# filename="geq_file";
# [ -f "$filename" ] || cp -f /dev/null "$filename";
# str1=`echo $p1 | tr '@' '*'`;
# stmt="^.*${str1}.*";
# egrep "${stmt}" "${filename}" | cut -d '|' -f1,3,4 | awk '!x[$0]++' | nl -w1 -s '|';
# STATUS=$?;
# exit;
# ;;
reloadQuery)

dt=$(date +%Y-%m-%d"_"%T);

filename1="/ws/ger_file";
[ -f "$filename1" ] || echo "8|Y|$dt" > $filename1;
filename2="/ws/ges_file";
[ -f "$filename2" ] || echo "90|Y|$dt" > $filename2;
filename3="/ws/get_file";
[ -f "$filename3" ] || echo "DAILY|6|10|Y|$dt" > $filename3;
filename4="/ws/geu_file";
[ -f "$filename4" ] || echo "pass:wtftfx|Y|$dt" > $filename4;

c1=$(cat $filename1 | cut -d '|' -f1     | awk '!x[$0]++' | tr ' ' '\n');
c2=$(cat $filename2 | cut -d '|' -f1     | awk '!x[$0]++' | tr ' ' '\n');
c3=$(cat $filename3 | cut -d '|' -f1,2,3 | awk '!x[$0]++' | tr ' ' '\n');
c4=$(cat $filename4 | cut -d '|' -f1     | cut -d ':' -f2 | awk '!x[$0]++' | tr ' ' '\n');

echo "$c1|$c2|$c3|$c4";

if [[ $? != 0 ]]; then
 msg="[Failed]  LoginID: [${iUser}] Reload System Config Profile Failed";
else
 msg="[OK] LoginID: [${iUser}] Reload System Config Profile OK";
fi

echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table};

#echo "EOF";
exit $?;
;;

gemSave)
########################################################
filename="/ws/gem_file";
[ -f "$filename" ] || cp -f /dev/null "$filename";
mkdir -p $backupdir;
cp -f ${filename} ${filename}"_"${timeStamp};
mv -f ${filename}"_"${timeStamp} $backupdir;
########################################################

dt=$(date +%Y-%m-%d"_"%T);

stmt="^.*${p1}|.*";

str1="s/^"${p1}"|.*/"${p1}"|"${p2}"|"${p3}"|"${p4}"|"${dt}"/g";

str2="$ a"\\${p1}"|"${p2}"|"${p3}"|"${p4}"|"${dt}"";

if [ "${iType}" != "ADMIN" ]; then
grep -i "${stmt}" $filename &> /dev/null && sed -i "${str1}" $filename &> /dev/null && sed -i '$!N; /^\(.*\)\n\1$/!P; D' $filename &> /dev/null;
else
grep -i "${stmt}" $filename &> /dev/null && sed -i "${str1}" $filename &> /dev/null && sed -i '$!N; /^\(.*\)\n\1$/!P; D' $filename &> /dev/null  || sed "${str2}" -i $filename &> /dev/null && sed -i '$!N; /^\(.*\)\n\1$/!P; D' $filename &>/dev/null;
fi

cat $filename | nl -w1 -s '|';

if [[ $? != 0 ]]; then
 msg="[Failed]  loginID: [${iUser}] Save HostIP Profile Failed";
else
 msg="[OK] loginID: [${iUser}] Save HostIP Profile OK";
fi

echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table};

#echo "EOF";
exit $?;
;;

genSave)
########################################################
filename="/ws/gen_file";
[ -f "$filename" ] || cp -f /dev/null "$filename";
mkdir -p $backupdir;
cp -f ${filename} ${filename}"_"${timeStamp};
mv -f ${filename}"_"${timeStamp} $backupdir;
########################################################
dt=$(date +%Y-%m-%d"_"%T);

stmt="^${p1}|.*";

str1="s/^"${p1}"|.*/"${p1}"|"${p2}"|"${p3}"|"${p4}"|"${dt}"/g";
#str1="s/^"${p1}"|.*/"${p1}"|"$(escape_string "$NEW_PASSWORD")"|"${p3}"|"${p4}"|"${dt}"/g";

str2="$ a"\\${p1}"|"${p2}"|"${p3}"|"${p4}"|"${dt}"";
#str2="$ a"\\${p1}"|"$(escape_string "$NEW_PASSWORD")"|"${p3}"|"${p4}"|"${dt}"";

if [ "${iType}" != "ADMIN" ]; then
grep -i "${stmt}" $filename &> /dev/null && sed -i "${str1}" $filename &> /dev/null && sed -i '$!N; /^\(.*\)\n\1$/!P; D' $filename &> /dev/null;
sed -i 's/^M//g' $filename &> /dev/null;
else
grep -i "${stmt}" $filename &> /dev/null && sed -i "${str1}" $filename &> /dev/null && sed -i '$!N; /^\(.*\)\n\1$/!P; D' $filename &> /dev/null  || sed "${str2}" -i $filename &> /dev/null && sed -i '$!N; /^\(.*\)\n\1$/!P; D' $filename &>/dev/null;
sed -i 's/^M//g' $filename &> /dev/null;
fi

sed -i 's/\r//g' $filename &> /dev/null;

if [ "${iType}" != "ADMIN" ]; then
grep -i "${stmt}" $filename | nl -w1 -s '|';
else
cat $filename | nl -w1 -s '|';
fi

if [[ $? != 0 ]]; then
 msg="[Failed]  loginID: [${iUser}] Save User Login Profile Failed";
else
 msg="[OK] loginID: [${iUser}] Save User Login Profile OK";
fi
echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table};

#echo "EOF";
exit $?;
;;

geoSave)
#######################################################
filename="/ws/geo_file";
[ -f "$filename" ] || cp -f /dev/null "$filename";
mkdir -p $backupdir;
cp -f ${filename} ${filename}"_"${timeStamp};
mv -f ${filename}"_"${timeStamp} $backupdir;
########################################################

dt=$(date +%Y-%m-%d"_"%T);

stmt="^${p1}|.*";

str1="s/^"${p1}"|.*/"${p1}"|"${p2}"|"${p3}"|"${dt}"/g";

str2="$ a"\\${p1}"|"${p2}"|"${p3}"|"${dt}"";

#str1="s/\\("${p1}"\)\\(.*|.*|\).*/\\1\2"${p2}"/g";
#
#str2="$ a"\\${p1}"|"${p2}"|"${p3}"";

if [ "${iType}" != "ADMIN" ]; then
grep -i "${stmt}" $filename &> /dev/null && sed -i "${str1}" $filename &> /dev/null && sed -i '$!N; /^\(.*\)\n\1$/!P; D' $filename &> /dev/null
else
grep -i "${stmt}" $filename &> /dev/null && sed -i "${str1}" $filename &> /dev/null && sed -i '$!N; /^\(.*\)\n\1$/!P; D' $filename &> /dev/null  || sed "${str2}" -i $filename &> /dev/null && sed -i '$!N; /^\(.*\)\n\1$/!P; D' $filename &>/dev/null
fi

cat $filename | nl -w1 -s '|';

if [[ $? != 0 ]]; then
 msg="[Failed]  loginID: [${iUser}] Save OS Account Profile Failed";
else
 msg="[OK] loginID: [${iUser}] Save OS Account Profile OK";
fi
echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table};

#echo "EOF";
exit $?;
;;

gepSave)
########################################################
filename="/ws/gep_file";
[ -f "$filename" ] || cp -f /dev/null "$filename";
mkdir -p $backupdir;
cp -f ${filename} ${filename}"_"${timeStamp};
mv -f ${filename}"_"${timeStamp} $backupdir;
########################################################

str1=`echo $p2 | tr '@' '*'`;

#stmt="^.*${str1}.*";

stmt="^${str1}.*";

variable=$p1;

echo $variable &>> /tmp/gep_file.log

for i in $(echo $variable | sed "s/,/ /g")
do
## call procedure or other scripts here below

icode1=`echo $i | cut -d '@' -f1`; # tomas|op11@N
icode2=`echo $i | cut -d '@' -f2`; # N

str1="s/^"${icode1}"@.*/"${icode1}"@"${icode2}"/g";

str2="$ a"\\${icode1}"@"${icode2}"";

grep -i "^.*${icode1}.*" $filename &> /dev/null && sed -i "${str1}" $filename &> /dev/null && sed -i '$!N; /^\(.*\)\n\1$/!P; D' $filename &> /dev/null  || sed "${str2}" -i $filename &> /dev/null && sed -i '$!N; /^\(.*\)\n\1$/!P; D' $filename &>/dev/null

done;

egrep "${stmt}"  $filename | tr '@' '|'  | nl -w1 -s '|';

if [[ $? != 0 ]]; then
 msg="[Failed]  loginID: [${iUser}] Save Authorized Profile Failed";
else
 msg="[OK] loginID: [${iUser}] Save Authorized Profile OK";
fi
echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table};

#echo "EOF";
exit $?;
;;

gerSave)
########################################################
filename="/ws/ger_file";

[ -f "$filename" ] || cp -f /dev/null "$filename";
mkdir -p $backupdir;
cp -f ${filename} ${filename}"_"${timeStamp};
mv -f ${filename}"_"${timeStamp} $backupdir;
########################################################

dt=$(date +%Y-%m-%d"_"%T);

#stmt="^.*${p1}|.*";

#str1="s/^"${p1}".*/"${p1}"|"${p2}"|"${p3}"|"${p4}"|"${dt}"/g";

#str2="$ a"\\${p1}"|"${p2}"|"${p3}"|"${p4}"|"${dt}"";

echo $p1"|Y|"$dt >  $filename;

#if [ "${iType}" != "ADMIN" ]; then
#echo "${p1}|Y|${dt}" > $filename &> /dev/null;
#grep -i "${stmt}" $filename &> /dev/null && sed -i "${str1}" $filename &> /dev/null && sed -i '$!N; /^\(.*\)\n\1$/!P; D' $filename &> /dev/null;
#else
#echo "${p1}|Y|${dt}" > $filename &> /dev/null;
#grep -i "${stmt}" $filename &> /dev/null && sed -i "${str1}" $filename &> /dev/null && sed -i '$!N; /^\(.*\)\n\1$/!P; D' $filename &> /dev/null  || sed "${str2}" -i $filename &> /dev/null && sed -i '$!N; /^\(.*\)\n\1$/!P; D' $filename &>/dev/null;
#fi

#cat $filename | nl -w1 -s '|';

if [[ $? != 0 ]]; then
 msg="[Failed]  loginID: [${iUser}] Save Password Config Profile Failed";
else
 msg="[OK] loginID: [${iUser}] Save Password Config Profile OK";
fi

echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table};

#echo "EOF";
exit $?;
;;
gesSave)
########################################################
filename="/ws/ges_file";

[ -f "$filename" ] || cp -f /dev/null "$filename";
mkdir -p $backupdir;
cp -f ${filename} ${filename}"_"${timeStamp};
mv -f ${filename}"_"${timeStamp} $backupdir;
########################################################

dt=$(date +%Y-%m-%d"_"%T);

#stmt="^.*${p1}|.*";

#str1="s/^"${p1}".*/"${p1}"|"${p2}"|"${p3}"|"${p4}"|"${dt}"/g";

#str2="$ a"\\${p1}"|"${p2}"|"${p3}"|"${p4}"|"${dt}"";

echo $p1"|Y|"$dt >  $filename;

#if [ "${iType}" != "ADMIN" ]; then
#echo "${p1}|Y|${dt}" > $filename &> /dev/null;
#grep -i "${stmt}" $filename &> /dev/null && sed -i "${str1}" $filename &> /dev/null && sed -i '$!N; /^\(.*\)\n\1$/!P; D' $filename &> /dev/null;
#else
#echo "${p1}|Y|${dt}" > $filename &> /dev/null;
#grep -i "${stmt}" $filename &> /dev/null && sed -i "${str1}" $filename &> /dev/null && sed -i '$!N; /^\(.*\)\n\1$/!P; D' $filename &> /dev/null  || sed "${str2}" -i $filename &> /dev/null && sed -i '$!N; /^\(.*\)\n\1$/!P; D' $filename &>/dev/null;
#fi

#cat $filename | nl -w1 -s '|';

if [[ $? != 0 ]]; then
 msg="[Failed]  loginID: [${iUser}] Save Expire Config Profile Failed";
else
 msg="[OK] loginID: [${iUser}] Save Expire Config Profile OK";
fi

echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table};

#echo "EOF";
exit $?;
;;
getSave)
########################################################
filename="/ws/get_file";

[ -f "$filename" ] || cp -f /dev/null "$filename";
mkdir -p $backupdir;
cp -f ${filename} ${filename}"_"${timeStamp};
mv -f ${filename}"_"${timeStamp} $backupdir;
########################################################

dt=$(date +%Y-%m-%d"_"%T);

p2=`echo $p2 | tr '@' '*'`;
p3=`echo $p3 | tr '@' '*'`;
p4=`echo $p4 | tr '@' '*'`;

case "$p4" in
    DAILY) 
    (crontab -l | grep -i -v -F "pmsGP"; echo "$p2 $p3 * * * /ws/pmsGP.sh ADMIN pmsSave admin 1234 \"$p1\" 1 1 1 &>/dev/null") | crontab -
    ;;
    WEEKLY) 
    (crontab -l | grep -i -v -F "pmsGP"; echo "$p2 $p3 * * 0 /ws/pmsGP.sh ADMIN pmsSave admin 1234 \"$p1\" 1 1 1 &>/dev/null") | crontab -
    ;;
    MONTHLY) 
    (crontab -l | grep -i -v -F "pmsGP"; echo "$p2 $p3 1 * * /ws/pmsGP.sh ADMIN pmsSave admin 1234 \"$p1\" 1 1 1 &>/dev/null") | crontab -
    ;;
    HOURLY) 
    (crontab -l | grep -i -v -F "pmsGP"; echo "$p2 * * * * /ws/pmsGP.sh ADMIN pmsSave admin 1234 \"$p1\" 1 1 1 &>/dev/null") | crontab -
    ;;
    *) 
    (crontab -l | grep -i -v -F "pmsGP"; echo "$p2 $p3 * * * /ws/pmsGP.sh ADMIN pmsSave admin 1234 \"$p1\" 1 1 1 &>/dev/null") | crontab -
    ;;
esac

echo "$p4|$p3|$p2|Y|$dt" >  $filename;

#echo "$p2 $p3 * * * /ws/pmsGP.sh ADMIN pmsSave admin 1234 \"$p1\" 1 1 1 &>/dev/null" > $filename;
#(crontab -l | grep -i -v -F "pmsGP"; echo "$p2 $p3 * * * /ws/pmsGP.sh ADMIN pmsSave admin 1234 \"$p1\" 1 1 1 &>/dev/null") | crontab -

if [[ $? != 0 ]]; then
 msg="[Failed]  loginID: [${iUser}] Save CronJob Scheduler Profile Failed";
else
 msg="[OK] loginID: [${iUser}] Save CronJob Scheduler Profile OK";
fi

echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table};

#echo "EOF";
exit $?;
;;

geuSave)

filename="/ws/geu_file";
[ -f "$filename" ] || echo "pass:wtftfx" > $filename;
mkdir -p $backupdir;
cp -f ${filename} ${filename}"_"${timeStamp};
mv -f ${filename}"_"${timeStamp} $backupdir;

dt=$(date +%Y-%m-%d"_"%T);

seeds=$(cat $filename | cut -d '|' -f1 | awk '!x[$0]++' | tr ' ' '\n');

cat /ws/pms_file | openssl enc -aes-256-cbc -d -pbkdf2 -a -salt -pass $seeds > /ws/pms_file.out

echo "pass:$p1|Y|$dt" >  $filename;

seeds=$(cat $filename | cut -d '|' -f1 | awk '!x[$0]++' | tr ' ' '\n');

cat /ws/pms_file.out | openssl enc -aes-256-cbc -pbkdf2 -a -salt -pass $seeds > /ws/pms_file

if [[ $? != 0 ]]; then
 msg="[Failed]  LoginID: [${iUser}] Update Cipher Seeds Profile Failed";
else
 msg="[OK] LoginID: [${iUser}] Update Cipher Seeds Profile OK";
fi

echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table};

#echo "EOF";
exit $?;
;;
# geqSave)
#
# filename="geq_file";
#
# [ -f "$filename" ] || cp -f /dev/null "$filename";
#
# stmt="^${p1}|.*";
#
# str1="s/^"${p1}".*/"${p1}"|"${p2}"|"${p3}"|"${p4}"/g";
#
# str2="$ a"\\${p1}"|"${p2}"|"${p3}"|"${p4}"";
#
# if [ "${iType}" != "ADMIN" ]; then
#
# grep -i "${stmt}" $filename &> /dev/null && sed -i "${str1}" $filename &> /dev/null && sed -i '$!N; /^\(.*\)\n\1$/!P; D' $filename &> /dev/null
#
# else
#
# grep -i "${stmt}" $filename &> /dev/null && sed -i "${str1}" $filename &> /dev/null && sed -i '$!N; /^\(.*\)\n\1$/!P; D' $filename &> /dev/null  || sed "${str2}" -i $filename &> /dev/null && sed -i '$!N; /^\(.*\)\n\1$/!P; D' $filename &>/dev/null
#
# fi
#
# cat $filename
#
# STATUS=$?;
#
# exit;
# ;;
genDel)
########################################################
filename="/ws/gen_file";
[ -f "$filename" ] || cp -f /dev/null "$filename";
mkdir -p $backupdir;
cp -f ${filename} ${filename}"_"${timeStamp};
mv -f ${filename}"_"${timeStamp} $backupdir;
########################################################

str1="${p1}d";

if [ "${iType}" != "ADMIN" ]; then
stmt="^.*${iUser}|.*";
else
stmt="^.*";
fi

sed -i "${str1}" $filename &> /dev/null ;

if [[ $? != 0 ]]; then
 msg="[Failed]  loginID: [${iUser}] Delete User Login Profile Failed";
else
 msg="[OK] loginID: [${iUser}] Delete User Login Profile OK";
fi

if [ "${iType}" != "ADMIN" ]; then
grep -i "${stmt}" $filename | nl -w1 -s '|';
else
cat $filename | nl -w1 -s '|';
fi

echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table};
######## 20180719 add ############################################################
str1=$(cat /ws/gen_file | awk -F '|' '{print "^"$1}' | tr '\n' '|' | sed 's/.$//');
egrep -i "$str1" /ws/gep_file > $tempfile
mv -f $tempfile /ws/gep_file &>/dev/null
#################################################################################
#echo "EOF";
exit $?;
;;
geoDel)
########################################################
filename="/ws/geo_file";
[ -f "$filename" ] || cp -f /dev/null "$filename";
mkdir -p $backupdir;
cp -f ${filename} ${filename}"_"${timeStamp};
mv -f ${filename}"_"${timeStamp} $backupdir;
########################################################

str1="${p1}d";

if [ "${iType}" != "ADMIN" ]; then
stmt="^.*${iUser}|.*";
else
stmt="^.*";
fi

sed -i "${str1}" $filename &> /dev/null ;

if [[ $? != 0 ]]; then
 msg="[Failed]  loginID: [${iUser}] Delete OS Account Profile Failed";
else
 msg="[OK] loginID: [${iUser}] Delete OS Account Profile OK";
fi

#if [ "${iType}" != "ADMIN" ]; then
#grep -i "${stmt}" $filename | nl -w1 -s '|';
#else
cat $filename | nl -w1 -s '|';
#fi

echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table};

######## 20180719 add ############################################################
str1=$(cat /ws/geo_file | awk -F '|' '{print $1"@"}' | tr '\n' '|' | sed 's/.$//');
egrep -i "$str1" /ws/gep_file > $tempfile
mv -f $tempfile /ws/gep_file &>/dev/null
#################################################################################
#echo "EOF";
exit $?;
;;
gemDel)
########################################################
filename="/ws/gem_file";
[ -f "$filename" ] || cp -f /dev/null "$filename";
mkdir -p $backupdir;
cp -f ${filename} ${filename}"_"${timeStamp};
mv -f ${filename}"_"${timeStamp} $backupdir;
########################################################

str1="${p1}d";

if [ "${iType}" != "ADMIN" ]; then
stmt="^.*${iUser}|.*";
else
stmt="^.*";
fi

sed -i "${str1}" $filename &> /dev/null ;

if [[ $? != 0 ]]; then
 msg="[Failed]  loginID: [${iUser}] Delete HostIP Profile Failed";
else
 msg="[OK] loginID: [${iUser}] Delete HostIP Profile OK";
fi

#if [ "${iType}" != "ADMIN" ]; then
#grep -i "${stmt}" $filename | nl -w1 -s '|';
#else
cat $filename | nl -w1 -s '|';
#fi

echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table};

#echo "EOF";
exit $?;
;;
pmsSave|pms2Save)
########################################################
filename="/ws/pms_file";
mkdir -p $backupdir;
cp -f ${filename} ${filename}"_"${timeStamp};
mv -f ${filename}"_"${timeStamp} $backupdir;
########################################################

# main change use passwd process #
echo "`date +'%Y-%m-%d %H:%M:%S'`: Starting process for change system account's password ...";

icheck=$(cat /ws/gem_file | grep ".*Y.*" | awk -F'|' '{print $1}'| xargs -I {} -P 300 /usr/sbin/fping -r 3 {} 2>/dev/null | grep -i -v "alive" | wc -l);
if [ "$icheck" -ne 0 ]; then
echo "`date +'%Y-%m-%d %H:%M:%S'`: /usr/sbin/fping check all of host status ...FAIL";
echo "`date +'%Y-%m-%d %H:%M:%S'`: Please contanct system admin for help.";
echo "********* THE END *************************************************";
msg="[Failed] loginID: [${iUser}] Change User Password Profile Failed";
echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table};
#echo "EOF";
exit $?;
else
echo "`date +'%Y-%m-%d %H:%M:%S'`: /usr/sbin/fping check all of host status ...[OK]";
fi

cat /ws/gem_file | grep ".*Y.*" | awk -F'|' '{print $1}'| xargs -I {} -P 300 ssh -l cose -o ConnectTimeout=10 {} "echo 1" &>/ws/foo;
sshresult=$(egrep -i "abort" /ws/foo | wc -l);
if [ "$sshresult" -ne 0 ]; then
echo "`date +'%Y-%m-%d %H:%M:%S'`: check ssh service is not avaliable ...FAIL";
echo "`date +'%Y-%m-%d %H:%M:%S'`: Please contanct system admin for help.";
echo "********* THE END *************************************************";
msg="[Failed] loginID: [${iUser}] Change User Password Profile Failed";
echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table};
#echo "EOF";
exit $?;
else
echo "`date +'%Y-%m-%d %H:%M:%S'`: check ssh service is avaliable ...[OK]";
fi


variable=$p1;
userlist=" egrep ";

for i in $(echo $variable | sed "s/|/ /g")
do
   userlist+=" -e \"^${i}\|\" ";
done;
#printf " %s " $userlist;
if [ "$variable" == "all" ] ; then
    userlist=" grep '^.*Y' ";
  # userlist=" egrep -v \"root|changer\" ";
  # userlist=" egrep -v \"root|alex|changer|peter|ap1|sybase\" ";
fi

docommand="grep \"^.*Y\" /ws/geo_file | $userlist  | cut -d '|' -f1"

filename="/ws/geo_file";
[ -f "$filename" ] || cp -f /dev/null "$filename";
#geoData=`grep "^.*Y" $filename | grep -E "${stmt}" | cut -d '|' -f1`;
geoData=`eval $docommand`;
[ ! -z "$geoData" -a "$geoData" != " " ] || exit 0;
echo "`date +'%Y-%m-%d %H:%M:%S'`: retrieving all system accounts of hosts ...[OK]";
echo "`date +'%Y-%m-%d %H:%M:%S'`:"$geoData;

filename="/ws/gem_file";
[ -f "$filename" ] || cp -f /dev/null "$filename";
gemData=`grep "^.*Y" $filename`;
[ ! -z "$gemData" -a "$gemData" != " " ] || exit 0;
echo "`date +'%Y-%m-%d %H:%M:%S'`: retrieving all ip address of hosts ...[OK]";
#echo "`date +'%Y-%m-%d %H:%M:%S'`:"$gemData;

linux_list='';
aix_list='';
sunos_list='';
cmd_list='';
pfile="";

cp -f /dev/null $tempfile;

pwd_num=$(awk -F'|' '{print $1}' /ws/ger_file|xargs);

if [ "$pwd_num" -lt 8 ] ; then
   pwd_num=8;
fi

echo "`date +'%Y-%m-%d %H:%M:%S'`:password length:$pwd_num";
# for loop users & accounts and generate random password then encrpty
for i in `(echo $geoData | tr " " "\n")`
do

#newpwd=`head -10 /dev/urandom | tr -dc '1234567890@qwerQWERTasdfgASDFGzxcvbZXCVBpoiuyPOIUYlkjhLKJHmnMN' | sed 's/[a-zA-Z0-9]/@/3' | sed 's/@/w/2' | head -c $pwd_num`;
newpwd=`head -10 /dev/urandom | tr -dc '1234567890@qwerQWERTasdfgASDFGzxcvbZXCVBpoiuyPOIUYlkjhLKJHmnMN' | sed 's/[A-Z0-9]/@/3' | head -c $pwd_num | sed 's/[a-zA-Z]/./4'`;
#newpwd=$(pwgen -syBnv -1 | tr '.|!,`><][}{)(:&"$#?%=\*' '@');

echo "`date +'%Y-%m-%d %H:%M:%S'`: generate random password for user => [ $i ] change to [ $newpwd ]";

a=" echo ";
b="\"$i:$newpwd\"";
c1=" | sudo chpasswd &>/dev/null || true ; "
c2=" | sudo chpasswd -c &>/dev/null || true ; "
c3=" | sudo changepass &>/dev/null || true ; "
#c1=" | sudo chpasswd &>/dev/null ; "
#c2=" | sudo chpasswd -c &>/dev/null ; "
#c3=" | sudo changepass &>/dev/null ; "

linux_list+=$a$b$c1;
aix_list+=$a$b$c2;
sunos_list+=$a$b$c3;

#echo $i"|"$newpwd | tee -a $tempfile ; # save to local disk file for sake # user|passwordd|NOW
#echo $i"|"$newpwd >> $tempfile ; # save to local disk file for sake # user|passwordd|NOW
# echo "'"$i"|"$newpwd"'" >> $tempfile ; # save to local disk file for sake # user|passwordd|NOW
pfile+="'"$i"|"$newpwd"'\n";
done

#exit 0;

echo "********************************************************";

#linux_list=$(echo $linux_list | sed "s/&&$//1");
linux_list=$(echo $linux_list | sed "s/;$//1");
linux_list="\"$linux_list\"";

#aix_list=$(echo $aix_list | sed "s/&&$//1");
aix_list=$(echo $aix_list | sed "s/;$//1");
aix_list="\"$aix_list\"";

#sunos_list=$(echo $sunos_list | sed "s/&&$//1");
sunos_list=$(echo $sunos_list | sed "s/;$//1");
sunos_list="\"$sunos_list\"";

hostip="127.0.0.1";

data="";

cmd_list=$linux_list;

for p in `echo $gemData | tr " " "\n" | sort -n | uniq` # start loop for all Linux server ip
do

data="";

hostip=`echo $p | awk -F '|' '{print $1}'`;
myhostname=`echo $p | awk -F '|' '{print $2}'`;

echo "`date +'%Y-%m-%d %H:%M:%S'`: check operatiing system type ...";

if  [[ "`echo $p | awk -F '|' '{print $3}'`" == "Linux" ]]; then
echo "`date +'%Y-%m-%d %H:%M:%S'`: operating system (Linux)";
cmd_list=$linux_list;
elif [[ "`echo $p | awk -F '|' '{print $3}'`" == "AIX" ]]; then
echo "`date +'%Y-%m-%d %H:%M:%S'`: operating system (AIX)";
cmd_list=$aix_list;
elif [[ "`echo $p | awk -F '|' '{print $3}'`" == "SunOS" ]]; then
echo "`date +'%Y-%m-%d %H:%M:%S'`: operating system (SunOS)";
cmd_list=$sunos_list;
else
echo "`date +'%Y-%m-%d %H:%M:%S'`: operating system (unknown)";
cmd_list=$linux_list;
fi

echo "`date +'%Y-%m-%d %H:%M:%S'`: [SERVER CN] : $myhostname";
echo "`date +'%Y-%m-%d %H:%M:%S'`: [SERVER IP] : $hostip";
#echo "`date +'%Y-%m-%d %H:%M:%S'`:[SSH COMMAND]:";
#echo $cmd_list;

cmd_list="\"$cmd_list & \"";

ssh -o ConnectTimeout=9 root@$hostip $cmd_list;
#ssh -o StrictHostKeyChecking=no -o ConnectTimeout=9 cose@$hostip $cmd_list;

STATUS=$?
echo "`date +'%Y-%m-%d %H:%M:%S'`: [DEBUG] SSH COMMAND RETURN CODE => $STATUS";
if [[ $STATUS -ne 0 ]]; then
  echo "`date +'%Y-%m-%d %H:%M:%S'`|ERROR|$hostip|An error occurred when update user's password|SSH COMMAND";
  failedfile+=${hostip}"#"${myhostname}",";
  continue;
else
okfile+=${hostip}"#"${myhostname}",";
fi

#okfile+=${hostip}"#"${myhostname}",";

echo "`date +'%Y-%m-%d %H:%M:%S'`: update ($hostip) system account's password ...done";
echo "*********************************************************";

done

ok_count=`echo ${okfile}     | sed "s/,$//1" | grep "." | tr ',' '\n' | wc -l`;
no_count=`echo ${failedfile} | sed "s/,$//1" | grep "." | tr ',' '\n' | wc -l`;

echo "`date +'%Y-%m-%d_%H:%M:%S'`: change user's password : SUCCESS (total): $ok_count";
echo "`date +'%Y-%m-%d_%H:%M:%S'`: change user's password : FAILED  (total): $no_count";

echo ${failedfile} | sed "s/,$//1" | grep "." | tr ',' '\n' | nl -w1 -s '|';

# telegram notice

echo "********* RETURN RESULT ********************************";

#echo $okfile;
#echo $pfile ;

#tbl1=`echo ${okfile} | sed "s/,$//1"`;

#lsign1="";
#rsign1="";
#lsign2="";
#rsign2="";

tbl2=`echo -e $pfile | tr '\n' ',' | sed 's/.$//' | sed 's/.$//'`;

data=`echo $tbl2 | tr ',' '\n' | sed -e "s/'//g"`;

#exit 0;

#lnum=`echo $tbl1 | tr ',' '\n' | wc -l`;
#rnum=`echo $tbl2 | tr ',' '\n' | wc -l`;

#if [ "$lnum" -gt 1 ]; then
#lsign1="{";
#rsign1="}";
#fi

#if [ "$rnum" -gt 1 ]; then
#lsign2="{";
#rsign2="}";
#fi

#cross_jon_table="printf \"%s\n\" ""$lsign1$tbl1$rsign1"\"\|\""$lsign2$tbl2$rsign2";

#tbl=`eval $cross_jon_table`;

#data=`echo $tbl | sed -e "s/#/|/g"`;

#cat /ws/pms_file | openssl enc -base64 -d > /ws/pms_file.out

cat /ws/pms_file | openssl enc -aes-256-cbc -d -pbkdf2 -a -salt -pass $seeds > /ws/pms_file.out

filename="/ws/pms_file.out";

dt=$(date +%Y-%m-%d"_"%T);

#echo "$data"
#exit 0;
for i in $(echo "$data")
do

col1=`echo $i | tr ' ' '\n' | cut -d '|' -f1`;  # username
col2=`echo $i | tr ' ' '\n' | cut -d '|' -f2`;  # password

str1="s/^"$col1"|.*/"$col1"|"$col2"|"$dt"/g";
str2=""$col1"|"$col2"|"$dt;
stmt="^"${col1}"|\.*";

grep -i "$stmt" $filename &>/dev/null && sed -i "$str1" $filename && sed -i '$!N; /^\(.*\)\n\1$/!P; D' $filename || echo "$str2" >> $filename && sed -i '$!N; /^\(.*\)\n\1$/!P; D' $filename &>/dev/null

#olist=$(grep -i -n "$stmt" $filename | awk -F ':' '{print $1}');
#line="";
#for h in $(echo $olist | tr ' ' '\n')
#do
#line+=$h"d;";
#done
#[ ! -z "$line" -a "$line" != " " ] && sed -i "$line" $filename &>/dev/null;
#echo "$col1|$col2|$dt" &>> $filename;

done

cat $filename;

echo "********* THE END ************************************";
#echo "`date +'%Y-%m-%d %H:%M:%S'`:all job is done";

if [[ $? != 0 ]]; then
 msg="[Failed] loginID: [${iUser}] Change User Password Profile Failed";
else
 msg="[OK] loginID: [${iUser}] Change User Password Profile OK";
fi

echo "${iUser}|${iMode}|${iType}|${msg}|$(date +%Y/%m/%d" "%T)" >> ${log_table};

#x=`echo -e $pfile | tr '\n' ',' | sed 's/.$//' | sed 's/.$//'`;
#echo "${x}"

#echo "`date +'%Y-%m-%d_%H:%M:%S'`: PMS : FAILED : $nocount" | nc -w 1 192.168.6.185 8989
#echo "`date +'%Y-%m-%d %H:%M:%S'`: Ping check fail : $icheck";
#echo "`date +'%Y-%m-%d %H:%M:%S'`: ssh check fail : $sshresult";
echo "`date +'%Y-%m-%d %H:%M:%S'`: All job is done";
#echo "EOF";

#cat $filename | openssl enc -base64 > /ws/pms_file
cat $filename | openssl enc -aes-256-cbc -pbkdf2 -a -salt -pass $seeds > /ws/pms_file

# cat /ws/pms_file | openssl enc -aes-256-cbc -d -pbkdf2 -a -salt -pass pass:wtftfx1 | awk -F'|' '{print "sshpass -p "$2" ssh -l "$1" pfmea1 id "$1}' | xargs -I {} -P 300 bash -c {}

######################################################################################
# userlist password Single Sign On data sync
##################################################################################### 
/ws/config_sync.sh &>/dev/null
#sort /ws/userlist > /tmp/t1
#sort /ws/gen_file > /tmp/t2 
#join -t '|' -o 1.1,1.2,1.3,2.2 /tmp/t1 /tmp/t2 > /tmp/t3
#awk -F'|' 'BEGIN{ print "<?xml version=\"1.0\" encoding=\"utf-8\"?>"; print "<data>" ;}
#NR>1{  print "<user id=\""$1"\" group=\""$3"\" name=\""$2"\" password=\""$4"\" />" }
#END{ print "</data>"}' /tmp/t3 > /ws/drs/config.xml
#######################################################################################

rm -rf $filename &>/dev/null

# sms notice
#date_time=`date +%Y-%m-%d_%T`;
# telegram notice
#echo "`date +'%Y-%m-%d %H:%M:%S'`: system change password success: $ok_count ; fail: $no_count" | nc -w 1 192.168.6.185 8989

exit $?;
;;
#cronSave)
#(crontab -l | grep -i -v -F "pmsGP"; echo "10 6 * * * /ws/pmsGP.sh ADMIN pmsSave admin 1234 \"op1|op2\" 1 1 1 &>/dev/null") | crontab -
#echo "EOF";
#exit $?
#;;
1)  # all ok
#    echo "Running"
    exit 0;
    ;;
*)  #echo "Removed double pms_scripts: $(date)" >> /var/log/pms.${NOW}.log
#    kill -9 $(pidof pmsGP.sh | awk '{print $1}')
    exit 0;
    ;;
esac

fi
