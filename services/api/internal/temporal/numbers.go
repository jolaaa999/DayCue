package temporal

import "strconv"

// cnDigits 只覆盖 0-9；中文口语里的时间表达几乎不会超过两位数。
var cnDigits = map[rune]int{
	'零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4,
	'五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
}

// cnNumber 把阿拉伯数字或简单中文数字（0-99）转成整数；无法识别时返回 -1。
// 之所以不引第三方库：我们只需要支持「八点」「二十三点」「十五分」这类口语量词。
func cnNumber(s string) int {
	if s == "" {
		return -1
	}
	if n, err := strconv.Atoi(s); err == nil {
		return n
	}
	runes := []rune(s)
	for i, r := range runes {
		if r == '十' {
			tens := 1
			if i > 0 {
				d, ok := cnDigits[runes[i-1]]
				if !ok {
					return -1
				}
				tens = d
			}
			// 只支持「X十Y」的个位数后缀，够用且不会误判。
			if i == len(runes)-1 {
				return tens * 10
			}
			if i == len(runes)-2 {
				if d, ok := cnDigits[runes[i+1]]; ok {
					return tens*10 + d
				}
			}
			return -1
		}
	}
	if len(runes) == 1 {
		if d, ok := cnDigits[runes[0]]; ok {
			return d
		}
	}
	return -1
}
