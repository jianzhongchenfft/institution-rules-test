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

健康三個片段由 part07.txt 依序串接後一次 eval，因此仍共享同一個 closure，不使用額外全域狀態。

## 健康資料安全
assessment_health_records 目前仍是一個 event 一筆紀錄，但後端 save_assessment_health 已依 p_section 局部更新：
- baseline / change：只更新 medical_info、medication_checks。
- status：只更新 health_items、health_notes、total_score、copied_from。
因此不同健康表單同時開啟時，不應以舊快照覆蓋另一區塊的新資料。

## SQL
- assessment-health-current.sql：現行測試版健康儲存函式，後續修改以此為準。
- assessment-health-supabase-20261001.sql：2026-10-01 開發過程與舊 form_code 轉換歷史，不再作為現行定義來源。

## 目前 form_code
- adl
- iadl
- health_medication
- health_status
- home_safety（尚待完成）
- support（尚待完成）
- spmsq
- gds15
- caregiver_burden（尚待完成）
- bsrs5（尚待完成）

## 後續開發規則
1. 不再把新量表直接寫進 assessment-patch.txt。
2. 新量表應有自己的 patch / RPC / history（如需要）。
3. 前次資料一律以「本次 planned_date 以前最近一筆已完成同類評估」判定，不依建立時間。
4. 開案基準型資料與後續變化型資料可共用同一工具名稱，但 UI 依 assessment_type 切換。
5. 紙本列印讀取當次已儲存快照；歷史修改軌跡另由 history 保留。
