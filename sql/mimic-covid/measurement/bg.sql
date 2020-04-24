-- The aim of this query is to pivot entries related to blood gases
-- which were found in LABEVENTS
WITH bg AS
(
select 
  -- spec_id only ever has 1 measurement for each itemid
  -- so, we may simply collapse rows using MAX()
    MAX(mrn) AS mrn
  , MAX(subject_id) AS subject_id
  , MAX(hadm_id) AS hadm_id
  , MAX(stay_id) AS stay_id
  , MAX(charttime) AS charttime
  -- spec_id *may* have different storetimes, so this is taking the latest
  , MAX(storetime) AS storetime
  , le.spec_id
  , MAX(CASE WHEN itemid = 52025 THEN value ELSE NULL END) AS specimen
  , MAX(CASE WHEN itemid = 50801 THEN valuenum ELSE NULL END) AS aado2
  , MAX(CASE WHEN itemid = 50802 THEN valuenum ELSE NULL END) AS baseexcess
  , MAX(CASE WHEN itemid = 50803 THEN valuenum ELSE NULL END) AS bicarbonate
  , MAX(CASE WHEN itemid = 50804 THEN valuenum ELSE NULL END) AS totalco2
  , MAX(CASE WHEN itemid = 50805 THEN valuenum ELSE NULL END) AS carboxyhemoglobin
  , MAX(CASE WHEN itemid = 50806 THEN valuenum ELSE NULL END) AS chloride
  , MAX(CASE WHEN itemid = 50808 THEN valuenum ELSE NULL END) AS calcium
  , MAX(CASE WHEN itemid = 50809 THEN valuenum ELSE NULL END) AS glucose
  , MAX(CASE WHEN itemid = 50810 and valuenum <= 100 THEN valuenum ELSE NULL END) AS hematocrit
  , MAX(CASE WHEN itemid = 50811 THEN valuenum ELSE NULL END) AS hemoglobin
  , MAX(CASE WHEN itemid = 50813 THEN valuenum ELSE NULL END) AS lactate
  , MAX(CASE WHEN itemid = 50814 THEN valuenum ELSE NULL END) AS methemoglobin
  , MAX(CASE WHEN itemid = 50815 THEN valuenum ELSE NULL END) AS o2flow
  -- fix a common unit conversion error for fio2
  -- atmospheric o2 is 20.89%, so any value <= 20 is unphysiologic
  -- usually this is a misplaced O2 flow measurement
  , MAX(CASE WHEN itemid = 50816 THEN
      CASE
        WHEN valuenum > 20 AND valuenum <= 100 THEN valuenum 
        WHEN valuenum > 0.2 AND valuenum <= 1.0 THEN valuenum*100.0
      ELSE NULL END
    ELSE NULL END) AS fio2
  , MAX(CASE WHEN itemid = 50817 AND valuenum <= 100 THEN valuenum ELSE NULL END) AS so2
  , MAX(CASE WHEN itemid = 50818 THEN valuenum ELSE NULL END) AS pco2
  , MAX(CASE WHEN itemid = 50819 THEN valuenum ELSE NULL END) AS peep
  , MAX(CASE WHEN itemid = 50820 THEN valuenum ELSE NULL END) AS ph
  , MAX(CASE WHEN itemid = 50821 THEN valuenum ELSE NULL END) AS po2
  , MAX(CASE WHEN itemid = 50822 THEN valuenum ELSE NULL END) AS potassium
  , MAX(CASE WHEN itemid = 50823 THEN valuenum ELSE NULL END) AS requiredo2
  , MAX(CASE WHEN itemid = 50824 THEN valuenum ELSE NULL END) AS sodium
  , MAX(CASE WHEN itemid = 50825 THEN valuenum ELSE NULL END) AS temperature
  , MAX(CASE WHEN itemid = 50807 THEN value ELSE NULL END) AS comments
FROM mimic_covid_hosp_phi.labevents le
where le.ITEMID in
-- blood gases
(
    52025 -- specimen
  , 50801 -- aado2
  , 50802 -- base excess
  , 50803 -- bicarb
  , 50804 -- calc tot co2
  , 50805 -- carboxyhgb
  , 50806 -- chloride
  -- , 52390 -- chloride, WB CL-
  , 50807 -- comments
  , 50808 -- free calcium
  , 50809 -- glucose
  , 50810 -- hct
  , 50811 -- hgb
  , 50813 -- lactate
  , 50814 -- methemoglobin
  , 50815 -- o2 flow
  , 50816 -- fio2
  , 50817 -- o2 sat
  , 50818 -- pco2
  , 50819 -- peep
  , 50820 -- pH
  , 50821 -- pO2
  , 50822 -- potassium
  -- , 52408 -- potassium, WB K+
  , 50823 -- required O2
  , 50824 -- sodium
  -- , 52411 -- sodium, WB NA +
  , 50825 -- temperature
)
GROUP BY le.spec_id
)
, stg_spo2 as
(
  select subject_id, charttime
    -- avg here is just used to group SpO2 by charttime
    , AVG(valuenum) as SpO2
  FROM mimic_covid_icu_phi.chartevents
  where ITEMID = 220277 -- O2 saturation pulseoxymetry
  and valuenum > 0 and valuenum <= 100
  group by subject_id, charttime
)
, stg_fio2 as
(
  select subject_id, charttime
    -- pre-process the FiO2s to ensure they are between 21-100%
    , max(
        case
          when valuenum > 0.2 and valuenum <= 1
            then valuenum * 100
          -- improperly input data - looks like O2 flow in litres
          when valuenum > 1 and valuenum < 20
            then null
          when valuenum >= 20 and valuenum <= 100
            then valuenum
      else null end
    ) as fio2_chartevents
  FROM mimic_covid_icu_phi.chartevents
  where ITEMID = 223835 -- Inspired O2 Fraction (FiO2)
  and valuenum > 0 and valuenum <= 100
  group by subject_id, charttime
)
, stg2 as
(
select bg.*
  , ROW_NUMBER() OVER (partition by bg.subject_id, bg.charttime order by s1.charttime DESC) as lastRowSpO2
  , s1.spo2
from bg
left join stg_spo2 s1
  -- same hospitalization
  on  bg.subject_id = s1.subject_id
  -- spo2 occurred at most 2 hours before this blood gas
  and s1.charttime between DATETIME_SUB(bg.charttime, INTERVAL 2 HOUR) and bg.charttime
where bg.po2 is not null
)
, stg3 as
(
select bg.*
  , ROW_NUMBER() OVER (partition by bg.subject_id, bg.charttime order by s2.charttime DESC) as lastRowFiO2
  , s2.fio2_chartevents
  -- create our specimen prediction
  ,  1/(1+exp(-(-0.02544
  +    0.04598 * po2
  + coalesce(-0.15356 * spo2             , -0.15356 *   97.49420 +    0.13429)
  + coalesce( 0.00621 * fio2_chartevents ,  0.00621 *   51.49550 +   -0.24958)
  + coalesce( 0.10559 * hemoglobin       ,  0.10559 *   10.32307 +    0.05954)
  + coalesce( 0.13251 * so2              ,  0.13251 *   93.66539 +   -0.23172)
  + coalesce(-0.01511 * pco2             , -0.01511 *   42.08866 +   -0.01630)
  + coalesce( 0.01480 * fio2             ,  0.01480 *   63.97836 +   -0.31142)
  + coalesce(-0.00200 * aado2            , -0.00200 *  442.21186 +   -0.01328)
  + coalesce(-0.03220 * bicarbonate      , -0.03220 *   22.96894 +   -0.06535)
  + coalesce( 0.05384 * totalco2         ,  0.05384 *   24.72632 +   -0.01405)
  + coalesce( 0.08202 * lactate          ,  0.08202 *    3.06436 +    0.06038)
  + coalesce( 0.10956 * ph               ,  0.10956 *    7.36233 +   -0.00617)
  + coalesce( 0.00848 * o2flow           ,  0.00848 *    7.59362 +   -0.35803)
  ))) as specimen_prob
from stg2 bg
left join stg_fio2 s2
  -- same patient
  on  bg.subject_id = s2.subject_id
  -- fio2 occurred at most 4 hours before this blood gas
  and s2.charttime between DATETIME_SUB(bg.charttime, INTERVAL 4 HOUR) and bg.charttime
  AND s2.fio2_chartevents > 0
where bg.lastRowSpO2 = 1 -- only the row with the most recent SpO2 (if no SpO2 found lastRowSpO2 = 1)
)
select
  stg3.mrn
  , stg3.subject_id
  , stg3.hadm_id
  , stg3.stay_id
  , stg3.charttime
  -- raw data indicating sample type, only present 80% of the time
  , specimen 
  -- prediction of specimen for missing data
  , case
        when specimen is not null then specimen
        when specimen_prob > 0.75 then 'ART'
      else null end as specimen_pred
  , specimen_prob

  -- oxygen related parameters
  , so2, spo2 -- note spo2 is FROM `physionet-data.mimiciii_clinical.chartevents`
  , po2, pco2
  , fio2_chartevents, fio2
  , aado2
  -- also calculate AADO2
  , case
      when  po2 is not null
        and pco2 is not null
        and coalesce(fio2, fio2_chartevents) is not null
       -- multiple by 100 because fio2 is in a % but should be a fraction
        then (coalesce(fio2, fio2_chartevents)/100) * (760 - 47) - (pco2/0.8) - po2
      else null
    end as aado2_calc
  , case
      when PO2 is not null and coalesce(fio2, fio2_chartevents) is not null
       -- multiply by 100 because fio2 is in a % but should be a fraction
        then 100*PO2/(coalesce(fio2, fio2_chartevents))
      else null
    end as paO2fio2ratio
  -- acid-base parameters
  , ph, baseexcess
  , bicarbonate, totalco2

  -- blood count parameters
  , hematocrit
  , hemoglobin
  , carboxyhemoglobin
  , methemoglobin

  -- chemistry
  , chloride, calcium
  , temperature
  , potassium, sodium
  , lactate
  , glucose

  -- ventilation stuff that's sometimes input
  -- , intubated, tidalvolume, ventilationrate, ventilator
  -- , peep, o2flow
  -- , requiredo2
from stg3
where lastRowFiO2 = 1 -- only the most recent FiO2
order by 1, charttime;