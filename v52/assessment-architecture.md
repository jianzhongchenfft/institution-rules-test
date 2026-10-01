# 評估管理模組架構（TEST）

更新日期：2026-10-02

## 原則
- 評估事件（assessment_events）負責一次正式評估的日期、類型、狀態與負責人。
- 評估工具（assessment_event_forms）只記該次要做哪些表單與各表單進度。
- 每張量表各自管理自己的資料與儲存 RPC，不在主程式堆疊量表細節。
- 主程式透過 ASSESSMENT_FORM_HANDLERS 註冊表決定 form_code 要開哪一個模組。
- 新增評估工具時，優先新增獨立 patch，再到 ASSESSMENT_FORMS / ASSESSMENT_FORM_HANDLERS 登記。

## 現行前端檔案
- assessment-patch.txt：評估首頁、事件建立／編輯、工具清單、表單註冊與導航。
- assessment-adl-patch.txt：ADL。
- assessment-iadl-patch.txt：IADL。
- assessment-spmsq-patch.txt：SPMSQ。
- assessment-gds15-patch.txt：GDS-15。
- assessment-health-core.txt：健康共用資料、前次紀錄判定、用藥資料模型與共用 helper。
- assessment-health-ui.txt：健康與用藥、身體健康10項畫面。
- assessment-health-save.txt：健康表單儲存、完成與開啟流程。
- assessment-home-safety-patch.txt：居家環境安全 21 項評估、前次帶入、風險變化比較與追蹤摘要。
- assessment-support-patch.txt：支持系統、家庭照顧安排、支持面向、經濟／社會資源與追蹤。

健康三個片段由 part07.txt 依序串接後一次 eval，因此仍共享同一個 closure，不使用額外全域狀態。

## 健康與用藥工具
assessment_health_records 仍是一個 event 一筆紀錄；使用者介面只保留一個 health_medication 工具。
同一份表單一次處理：
- 開案／後續健康現況
- 身體健康狀態10項
- 固定與短期用藥
- 用藥管理與安全
- 後續健康／就醫／用藥變化

完成確認時前端以 p_section='all' 一次儲存，後端同時寫入健康、用藥與10項狀態，避免同一評估被拆成兩個完成狀態。

## SQL
- assessment-health-current.sql：現行測試版健康儲存函式，後續修改以此為準。
- 舊版 SQL 不留在主分支，需追溯時使用 Git 歷史或備份分支。

## 目前 form_code
- adl
- iadl
- health_medication
- home_safety
- support
- spmsq
- gds15
- caregiver_burden（尚待完成）
- bsrs5（尚待完成）

## 居家環境安全工具
- 21 項、6 大區域，不計算人工總分。
- 每項使用「安全／需改善／不適用＋備註」。
- 後續評估可由使用者主動帶入前次完成紀錄，不自動沿用。
- 系統自動比較新增風險、持續風險、已改善與不再適用。
- 樓梯、廚房依住宅概況可自動列為不適用。
- 有需改善項目時，完成確認前需留下改善建議、說明對象、個案／家屬回應與是否追蹤。

## 支持系統工具
- 不計分，以家庭／照顧安排、7 個支持面向、經濟狀況、社會資源與整體支持判斷組成。
- 後續評估由使用者主動「帶入前次資料」後逐項確認，不自動沿用。
- 支持面向使用「支持充足／部分不足／明顯不足／不適用」；非充足狀態需留下說明。
- 自動比較支持面向是否改善、減弱或持續需留意。
- 支持者清單只記錄與照顧或支持有關的重要人物，不取代家系圖。
- 整體支持若為部分不足或薄弱，完成前需記錄主要支持問題；需追蹤時需留下追蹤重點。

## 後續開發規則
1. 不再把新量表直接寫進 assessment-patch.txt。
2. 新量表應有自己的 patch / RPC / history（如需要）。
3. 前次資料一律以「本次 planned_date 以前最近一筆已完成同類評估」判定，不依建立時間。
4. 健康與用藥維持單一工具；UI 依 assessment_type 切換開案初始版／後續追蹤版，身體健康10項包含在同一張表單。
5. 紙本列印讀取當次已儲存快照；歷史修改軌跡另由 history 保留。
