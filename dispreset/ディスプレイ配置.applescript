-- ディスプレイ配置.app
-- ダブルクリックすると保存済みの配置プリセットを一覧表示し、選ぶとその配置に戻す。
-- エンジンは dispreset.py（displayplacer のラッパー）。

property toolPath : "/Users/ko_dai/制作物/dispreset/dispreset.py"
property saveLabel : "＋ いまの配置を新しく保存…"
property renameLabel : "✏️ プリセットの名前を変更…"
property deleteLabel : "🗑 プリセットを削除…"

on runDispreset(argStr)
	return do shell script "/usr/bin/python3 " & quoted form of toolPath & " " & argStr
end runDispreset

on presetNames()
	set namesText to ""
	try
		set namesText to runDispreset("names")
	end try
	set cleanNames to {}
	repeat with n in paragraphs of namesText
		if (n as text) is not "" then set end of cleanNames to (n as text)
	end repeat
	return cleanNames
end presetNames

on savePreset()
	set dlg to display dialog "この配置に名前をつけてください（例: 家、カフェ、会社）" default answer "" with title "いまの配置を保存" buttons {"やめる", "保存"} default button "保存"
	if button returned of dlg is "やめる" then return
	set newName to text returned of dlg
	if newName is "" then return

	-- 同名があれば上書き確認
	if presetNames() contains newName then
		display dialog "「" & newName & "」はすでにあります。上書きしますか？" buttons {"やめる", "上書きする"} default button "やめる" with title "いまの配置を保存"
		if button returned of result is "やめる" then return
	end if

	try
		set out to runDispreset("save " & quoted form of newName)
		display notification (paragraph 1 of out) with title "配置を保存しました"
	on error errMsg
		display alert "保存できませんでした" message errMsg
	end try
end savePreset

on watchIsOn()
	try
		return (runDispreset("watch-status") is "on")
	on error
		return false
	end try
end watchIsOn

on watchLabel()
	if watchIsOn() then
		return "🔄 iPad接続時の自動復元：オン（クリックでオフ）"
	else
		return "🔄 iPad接続時の自動復元：オフ（クリックでオン）"
	end if
end watchLabel

on toggleWatch()
	try
		if watchIsOn() then
			runDispreset("watch-off")
			display notification "iPadを繋いでも自動では戻しません" with title "自動復元をオフにしました"
		else
			set lastUsed to runDispreset("last")
			if lastUsed is "" then
				display dialog "自動復元は「最後に使った配置」に戻す仕組みです。まだ一度も配置を戻していないので、先に一覧から配置を選んで「この配置に戻す」を実行してください。" buttons {"わかった"} default button "わかった" with title "自動復元"
				return
			end if
			runDispreset("watch-on")
			display notification "iPadを繋ぐと「" & lastUsed & "」に戻ります" with title "自動復元をオンにしました"
		end if
	on error errMsg
		display alert "切り替えできませんでした" message errMsg
	end try
end toggleWatch

on renamePreset()
	set theNames to presetNames()
	if (count of theNames) is 0 then return
	set picked to choose from list theNames with title "名前を変更" with prompt "名前を変えたい配置を選んでください" OK button name "次へ" cancel button name "やめる"
	if picked is false then return
	set oldName to item 1 of picked

	set dlg to display dialog "「" & oldName & "」の新しい名前を入力してください" default answer oldName with title "名前を変更" buttons {"やめる", "変更する"} default button "変更する"
	if button returned of dlg is "やめる" then return
	set newName to text returned of dlg
	if newName is "" or newName is oldName then return

	try
		runDispreset("rename " & quoted form of oldName & " " & quoted form of newName)
		display notification oldName & " → " & newName with title "名前を変更しました"
	on error errMsg
		display alert "名前を変更できませんでした" message errMsg
	end try
end renamePreset

on deletePreset()
	set theNames to presetNames()
	if (count of theNames) is 0 then return
	set picked to choose from list theNames with title "プリセットを削除" with prompt "削除する配置を選んでください" OK button name "削除する" cancel button name "やめる"
	if picked is false then return
	set target to item 1 of picked
	display dialog "「" & target & "」を削除します。よろしいですか？" buttons {"やめる", "削除する"} default button "やめる" with title "プリセットを削除"
	if button returned of result is "削除する" then
		try
			runDispreset("rm " & quoted form of target)
			display notification target with title "プリセットを削除しました"
		on error errMsg
			display alert "削除できませんでした" message errMsg
		end try
	end if
end deletePreset

on applyPreset(target)
	try
		set out to runDispreset("apply " & quoted form of target)
		-- 未接続で飛ばした画面があれば、その行も一緒に知らせる
		if (count of paragraphs of out) > 1 then
			display notification (paragraph 2 of out) with title "配置を戻しました：" & target
		else
			display notification target with title "配置を戻しました"
		end if
	on error errMsg
		display alert "配置を戻せませんでした" message errMsg
	end try
end applyPreset

on run
	activate
	set theNames to presetNames()

	if (count of theNames) is 0 then
		display dialog "保存された配置がまだありません。いまのディスプレイ配置を保存しますか？" buttons {"やめる", "保存する"} default button "保存する" with title "ディスプレイ配置"
		if button returned of result is "保存する" then savePreset()
		return
	end if

	set watchItem to watchLabel()
	set choices to theNames & {saveLabel, renameLabel, deleteLabel, watchItem}
	set picked to choose from list choices with title "ディスプレイ配置" with prompt "戻したい配置を選んでください" default items (item 1 of theNames) OK button name "この配置に戻す" cancel button name "やめる"
	if picked is false then return
	set pick to item 1 of picked

	if pick is saveLabel then
		savePreset()
	else if pick is renameLabel then
		renamePreset()
	else if pick is deleteLabel then
		deletePreset()
	else if pick is watchItem then
		toggleWatch()
	else
		applyPreset(pick)
	end if
end run
