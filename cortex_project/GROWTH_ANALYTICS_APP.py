"""
Growth Analytics Dashboard
Streamlit-in-Snowflake app deployed by the CI pipeline alongside
GROWTH_ANALYTICS_SV and GROWTH_AGENT. Queries the demo tables directly.
"""

import streamlit as st
import snowflake.snowpark.context as ctx

session = ctx.get_active_session()

st.title("Growth Analytics Dashboard")
st.caption(
    "Live data from PM_AGENTS_DEMO.APP — refreshed every time the CI pipeline deploys."
)

# ── KPI cards ──────────────────────────────────────────────────────────────
kpis = session.sql("""
    SELECT
        COUNT(*)                                                        AS total_signups,
        ROUND(
            SUM(CASE WHEN converted_to_paid THEN 1 ELSE 0 END)
            * 100.0 / NULLIF(COUNT(*), 0), 1)                          AS conversion_rate,
        ROUND(SUM(CASE WHEN converted_to_paid THEN mrr_amount
                       ELSE 0 END), 2)                                 AS total_mrr
    FROM PM_AGENTS_DEMO.APP.SIGNUPS
""").to_pandas()

col1, col2, col3 = st.columns(3)
col1.metric("Total Signups",   int(kpis["TOTAL_SIGNUPS"][0]))
col2.metric("Conversion Rate", f'{kpis["CONVERSION_RATE"][0]}%')
col3.metric("Total MRR",       f'${kpis["TOTAL_MRR"][0]:,.0f}')

st.divider()

# ── Chart 1: signups by channel ────────────────────────────────────────────
st.subheader("Signups by Channel")
df_channel = session.sql("""
    SELECT signup_channel AS channel, COUNT(*) AS signups
    FROM PM_AGENTS_DEMO.APP.SIGNUPS
    GROUP BY 1
    ORDER BY 2 DESC
""").to_pandas()
st.bar_chart(df_channel.set_index("CHANNEL"))

# ── Chart 2: monthly signup trend ─────────────────────────────────────────
st.subheader("Monthly Signup Trend")
df_monthly = session.sql("""
    SELECT DATE_TRUNC('month', signup_date) AS month, COUNT(*) AS signups
    FROM PM_AGENTS_DEMO.APP.SIGNUPS
    GROUP BY 1
    ORDER BY 1
""").to_pandas()
st.line_chart(df_monthly.set_index("MONTH"))

# ── Chart 3: revenue by plan type ─────────────────────────────────────────
st.subheader("Revenue by Plan Type")
df_revenue = session.sql("""
    SELECT plan_type, ROUND(SUM(mrr_amount), 2) AS revenue
    FROM PM_AGENTS_DEMO.APP.SIGNUPS
    WHERE converted_to_paid
    GROUP BY 1
    ORDER BY 2 DESC
""").to_pandas()
st.bar_chart(df_revenue.set_index("PLAN_TYPE"))
