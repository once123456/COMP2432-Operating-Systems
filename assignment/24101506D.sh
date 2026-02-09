#!/bin/bash
# COMP2432 Operating Systems - NBA Player Performance Analyzer
# Student ID: 24101506D
# 最终修复：语法错误 + 子shell + 任意姓名长度 + 字段位置动态调整

set -eo pipefail

# ====================== 步骤1：参数合法性校验 ======================
if [ $# -lt 2 ]; then
    echo "Usage Error: $0 <player-name> <stat1> [stat2] [stat3] ..."
    echo "Supported Stats: FGM FGA FG% 3PM 3PA 3P% FTM FTA FT% OREB DREB REB AST STL BLK TO PF PTS +/-"
    exit 0
fi

SEARCH_PLAYER="$1"
shift
QUERY_STATS=("$@")

# 定义字段类型和百分比映射
declare -A FIELD_TYPE
declare -A CALC_MAP
FIELD_TYPE["FGM"]="sum"
FIELD_TYPE["FGA"]="sum"
FIELD_TYPE["FG%"]="calc"
FIELD_TYPE["3PM"]="sum"
FIELD_TYPE["3PA"]="sum"
FIELD_TYPE["3P%"]="calc"
FIELD_TYPE["FTM"]="sum"
FIELD_TYPE["FTA"]="sum"
FIELD_TYPE["FT%"]="calc"
FIELD_TYPE["OREB"]="sum"
FIELD_TYPE["DREB"]="sum"
FIELD_TYPE["REB"]="sum"
FIELD_TYPE["AST"]="sum"
FIELD_TYPE["STL"]="sum"
FIELD_TYPE["BLK"]="sum"
FIELD_TYPE["TO"]="sum"
FIELD_TYPE["PF"]="sum"
FIELD_TYPE["PTS"]="sum"
FIELD_TYPE["+/-"]="sum"

CALC_MAP["FG%"]="FGM|FGA"
CALC_MAP["3P%"]="3PM|3PA"
CALC_MAP["FT%"]="FTM|FTA"

# 校验统计项
for stat in "${QUERY_STATS[@]}"; do
    if [ -z "${FIELD_TYPE[$stat]-}" ]; then
        echo "Stat Error: '$stat' is not a supported statistic!"
        echo "Supported Stats: ${!FIELD_TYPE[@]}"
        exit 0
    fi
done

# ====================== 步骤2：定义数据存储结构 ======================
declare -A PLAYER_TOTAL  # 键：球员全名_统计项，值：总累加值
declare -A GAME_COUNT    # 键：球员全名，值：参赛场次
declare -a VALID_PLAYERS # 去重后的有效球员数组

# ====================== 步骤3：遍历并解析所有NBA游戏文件 ======================
for game_file in nba[0-9][0-9][0-9][0-9][0-9][0-9]*.txt; do
    [ -f "$game_file" ] || continue

    # 核心修复：AWK语法兼容（去掉嵌套撇号，改用字符类）
    player_data=$(awk -v search="$SEARCH_PLAYER" '
    BEGIN {
        # 定义基础字段位置（后续动态调整）
        BASE_FGM_POS=5; BASE_FGA_POS=6; BASE_THREEM_POS=8; BASE_THREEA_POS=9
        BASE_FTM_POS=11; BASE_FTA_POS=12; BASE_REB_POS=16; BASE_AST_POS=17
        BASE_STL_POS=18; BASE_BLK_POS=19; BASE_TO_POS=20; BASE_PF_POS=21
        BASE_PTS_POS=22; BASE_PM_POS=23
        # 定义姓名字符类（兼容撇号、横线）
        NAME_CHAR_CLASS = "[A-Za-z\x27-]"; # \x27是撇号的十六进制，避免转义错误
    }

    {
        gsub(/\|/, " ");
        gsub(/ +/, " ");
        $0 = $0;
    }

    # 过滤无效行
    /DNP|TOTALS|\|---/ || NF == 0 {
        if (curr_name != "") {
            split(curr_name, name_parts, " ");
            family_name = name_parts[length(name_parts)];
            if (curr_name ~ search || family_name ~ search) {
                output_clean_data(curr_name, curr_line);
            }
        }
        curr_name = "";
        curr_line = "";
        next;
    }

    # 匹配球员行（修复正则表达式）
    /^[A-Za-z]/ && ($0 ~ /F|G|C/ || $0 ~ /[0-9]+:[0-9]+/) {
        if (curr_name != "") {
            split(curr_name, name_parts, " ");
            family_name = name_parts[length(name_parts)];
            if (curr_name ~ search || family_name ~ search) {
                output_clean_data(curr_name, curr_line);
            }
        }
        
        curr_name = "";
        curr_line = $0;

        # 修复：提取任意长度的球员姓名（用字符类避免转义错误）
        for (i=1; i<=NF; i++) {
            # 使用预定义的字符类，避免嵌套撇号
            if ($i ~ "^" NAME_CHAR_CLASS "+$" && $i !~ /F|G|C/) {
                curr_name = (curr_name == "") ? $i : curr_name " " $i;
            } else {
                break;
            }
        }

        # 仅匹配球员保留数据，非匹配清空
        split(curr_name, name_parts, " ");
        family_name = name_parts[length(name_parts)];
        if (!(curr_name ~ search || family_name ~ search)) {
            curr_name = "";
            curr_line = "";
            next;
        }
        
        # 调试打印（输出到stderr，不混入数据流）
        printf "【DEBUG】匹配球员[%s] | 原始行：%s\n", curr_name, curr_line > "/dev/stderr";
        next;
    }

    # 跨行拼接（仅匹配球员）
    curr_name != "" {
        curr_line = curr_line " " $0;
        printf "【DEBUG】球员[%s]跨行拼接后：%s\n", curr_name, curr_line > "/dev/stderr";
        next;
    }

    END {
        if (curr_name != "") {
            split(curr_name, name_parts, " ");
            family_name = name_parts[length(name_parts)];
            if (curr_name ~ search || family_name ~ search) {
                output_clean_data(curr_name, curr_line);
            }
        }
    }

    # 核心函数：输出纯净数据（修复字段位置动态调整）
    function output_clean_data(name, line,    parts, has_pos, offset, fgm, fga, threepm, threepa, ftm, fta, reb, ast, stl, blk, to, pf, pts, pm) {
        # 初始化所有值为0
        fgm=fga=threepm=threepa=ftm=fta=reb=ast=stl=blk=to=pf=pts=pm=0;
        
        split(line, parts, " ");
        parts_len = length(parts);
        
        # 调试打印拆分结果（输出到stderr）
        printf "【DEBUG】解析球员[%s] | 数组长度：%d | 内容：", name, parts_len > "/dev/stderr";
        for (i=1; i<=parts_len; i++) {
            printf "[%d]=%s ", i, parts[i] > "/dev/stderr";
        }
        printf "\n" > "/dev/stderr";

        # 修复：动态判断是否有位置列（F/G/C），调整字段位置偏移
        has_pos = 0;
        offset = 0;
        # 先找到姓名结束的位置，再判断下一列是否是位置列
        name_parts_len = split(name, name_parts, " ");
        # 姓名占name_parts_len列，检查下一列是否是位置列
        if (parts_len > name_parts_len && parts[name_parts_len+1] ~ /F|G|C/) {
            has_pos = 1;
            offset = 0; # 有位置列，字段位置和原硬编码一致
        } else {
            offset = -1; # 无位置列，字段位置整体前移1位
        }
        printf "【DEBUG】球员[%s] | 有位置列：%d | 偏移量：%d\n", name, has_pos, offset > "/dev/stderr";

        # 动态调整字段位置（适配有无位置列）
        if (parts_len >= BASE_FGM_POS + offset) fgm = parts[BASE_FGM_POS + offset]+0;
        if (parts_len >= BASE_FGA_POS + offset) fga = parts[BASE_FGA_POS + offset]+0;
        if (parts_len >= BASE_THREEM_POS + offset) threepm = parts[BASE_THREEM_POS + offset]+0;
        if (parts_len >= BASE_THREEA_POS + offset) threepa = parts[BASE_THREEA_POS + offset]+0;
        if (parts_len >= BASE_FTM_POS + offset) ftm = parts[BASE_FTM_POS + offset]+0;
        if (parts_len >= BASE_FTA_POS + offset) fta = parts[BASE_FTA_POS + offset]+0;
        if (parts_len >= BASE_REB_POS + offset) reb = parts[BASE_REB_POS + offset]+0;
        if (parts_len >= BASE_AST_POS + offset) ast = parts[BASE_AST_POS + offset]+0;
        if (parts_len >= BASE_STL_POS + offset) stl = parts[BASE_STL_POS + offset]+0;
        if (parts_len >= BASE_BLK_POS + offset) blk = parts[BASE_BLK_POS + offset]+0;
        if (parts_len >= BASE_TO_POS + offset) to = parts[BASE_TO_POS + offset]+0;
        if (parts_len >= BASE_PF_POS + offset) pf = parts[BASE_PF_POS + offset]+0;
        if (parts_len >= BASE_PTS_POS + offset) pts = parts[BASE_PTS_POS + offset]+0;
        if (parts_len >= BASE_PM_POS + offset) pm = parts[BASE_PM_POS + offset]+0;

        # 调试打印提取结果（输出到stderr）
        printf "【DEBUG】球员[%s]提取结果：FGM=%s FGA=%s 3PM=%s PTS=%s REB=%s\n", 
            name, fgm, fga, threepm, pts, reb > "/dev/stderr";

        # 输出纯净数据（供Bash解析）
        printf "%s FGM=%s FGA=%s 3PM=%s 3PA=%s FTM=%s FTA=%s REB=%s AST=%s STL=%s BLK=%s TO=%s PF=%s PTS=%s +/-=%s\n",
            name, fgm, fga, threepm, threepa, ftm, fta, reb, ast, stl, blk, to, pf, pts, pm;
    }
    ' "$game_file")

    # ====================== 核心修复：避免子shell + 语法兼容 ======================
    # 1. 将awk解析结果写入临时文件，避免管道子shell
    temp_file=$(mktemp)
    echo "$player_data" > "$temp_file"

    # 2. 读取临时文件（无管道，变量在父shell生效）
    while IFS= read -r line; do
        [ -z "$line" ] && continue

        # 修复：提取任意长度的球员姓名（语法兼容版）
        full_name=$(echo "$line" | awk '
            BEGIN {
                NAME_CHAR_CLASS = "[A-Za-z\x27-]"; # 兼容撇号、横线
            }
            {
                name = "";
                for (i=1; i<=NF; i++) {
                    # 匹配姓名字符，且不是键值对（不含=）
                    if ($i ~ "^" NAME_CHAR_CLASS "+$" && $i !~ /=/) {
                        name = (name == "") ? $i : name " " $i;
                    } else {
                        break;
                    }
                }
                print name;
            }')
        # 过滤非球员名（排除调试文本）
        if ! echo "$full_name" | grep -q "^[A-Za-z\x27-]\+"; then
            continue
        fi

        # 打印Bash解析调试（仅目标球员）
        echo -e "\n【DEBUG】Bash解析到目标球员：$full_name"
        echo "【DEBUG】原始数据行：$line"

        # 初始化场次（父shell中生效）
        if [ -z "${GAME_COUNT[$full_name]-}" ]; then
            GAME_COUNT[$full_name]=1
            VALID_PLAYERS+=("$full_name")
            echo "【DEBUG】球员[$full_name]首次出现，场次=1"
        else
            GAME_COUNT[$full_name]=$((GAME_COUNT[$full_name] + 1))
            echo "【DEBUG】球员[$full_name]场次累加：${GAME_COUNT[$full_name]}"
        fi

        # 3. 解析统计项：修复进程替换语法，兼容低版本Bash
        # 先把键值对写入临时文件，再读取（替代进程替换，避免语法错误）
        kv_temp=$(mktemp)
        echo "$line" | awk '
            {
                for (i=1; i<=NF; i++) {
                    if ($i ~ /=/) { # 只处理键值对（如FGM=8）
                        split($i, kv, "=");
                        stat = kv[1];
                        val = kv[2]+0;
                        printf "%s=%s\n", stat, val;
                    }
                }
            }' > "$kv_temp"

        while IFS="=" read -r stat val; do
            [ -z "$stat" ] || [ -z "$val" ] && continue

            # 浮点累加（父shell中生效！）
            old_val=${PLAYER_TOTAL["$full_name"_"$stat"]:-0}
            new_val=$(echo "$old_val $val" | awk '{print $1 + $2}')
            PLAYER_TOTAL["$full_name"_"$stat"]=$new_val
            
            echo "【DEBUG】球员[$full_name]统计项[$stat]：旧值=$old_val + 新值=$val = 总值=$new_val"
        done < "$kv_temp"
        rm -f "$kv_temp" # 删除键值对临时文件
    done < "$temp_file"

    # 删除临时文件
    rm -f "$temp_file"
done

# ====================== 步骤4：去重VALID_PLAYERS ======================
declare -A TEMP_PLAYERS
VALID_PLAYERS=()
for p in "${!GAME_COUNT[@]}"; do
    if [ ${GAME_COUNT[$p]} -gt 0 ]; then
        TEMP_PLAYERS[$p]=1
    fi
done
for p in "${!TEMP_PLAYERS[@]}"; do
    VALID_PLAYERS+=("$p")
done

# ====================== 步骤5：容错处理 ======================
if [ ${#VALID_PLAYERS[@]} -eq 0 ]; then
    echo "Data Error: No valid playing data found for player '$SEARCH_PLAYER'!"
    exit 0
fi

# ====================== 步骤6：调试汇总（父shell中正确读取值） ======================
echo -e "\n====================================="
echo "【DEBUG】目标球员最终存储数据汇总"
echo "====================================="
for player in "${VALID_PLAYERS[@]}"; do
    echo -e "\n【DEBUG】球员：$player | 参赛场次：${GAME_COUNT[$player]}"
    echo "【DEBUG】统计项总值："
    for stat in "${QUERY_STATS[@]}"; do
        total=${PLAYER_TOTAL["$player"_"$stat"]:-0}
        echo "  - $stat: $total"
    done
done

# ====================== 步骤7：计算并格式化输出 ======================
echo -e "\n====================================="
echo "【最终输出】"
echo "====================================="
for player in "${VALID_PLAYERS[@]}"; do
    play_times=${GAME_COUNT[$player]}
    [ $play_times -eq 0 ] && continue

    if [ ${#VALID_PLAYERS[@]} -gt 1 ]; then
        echo -e "\n=== Player: $player ==="
    fi

    for stat in "${QUERY_STATS[@]}"; do
        if [ "${FIELD_TYPE[$stat]}" = "sum" ]; then
            total=${PLAYER_TOTAL["$player"_"$stat"]:-0}
            avg=$(echo "$total $play_times" | awk '{if($2==0) print "0.0"; else printf "%.1f", $1/$2}')
        else
            IFS="|" read -r hit stat_att <<< "${CALC_MAP[$stat]}"
            hit_total=${PLAYER_TOTAL["$player"_"$hit"]:-0}
            att_total=${PLAYER_TOTAL["$player"_"$stat_att"]:-0}
            avg=$(echo "$hit_total $att_total" | awk '{
                if ($2 == 0) {
                    print "0.0"
                } else {
                    printf "%.1f", ($1/$2)*100
                }
            }')
        fi
        echo "$stat $avg"
    done
done

exit 0