"""
Growth Analytics Dashboard
Streamlit-in-Snowflake app deployed by the CI pipeline alongside
GROWTH_ANALYTICS_SV and GROWTH_AGENT. Queries the demo tables directly.
"""

import streamlit as st
import snowflake.snowpark.context as ctx
import altair as alt

st.set_page_config(layout="wide", page_title="Growth Analytics")

session = ctx.get_active_session()

st.title("Growth Analytics Dashboard")
st.caption("Live data from PM_AGENTS_DEMO.APP — refreshed every time the CI pipeline deploys.")

# ── KPI cards ──────────────────────────────────────────────────────────────
kpis = session.sql("""
    SELECT
        COUNT(*)                                                        AS TOTAL_SIGNUPS,
        ROUND(
            SUM(CASE WHEN CONVERTED_TO_PAID THEN 1 ELSE 0 END)
            * 100.0 / NULLIF(COUNT(*), 0), 1)                          AS CONVERSION_RATE,
        ROUND(SUM(CASE WHEN CONVERTED_TO_PAID THEN MRR_AMOUNT
                       ELSE 0 END), 2)                                 AS TOTAL_MRR
    FROM PM_AGENTS_DEMO.APP.SIGNUPS
""").to_pandas()

kc1, kc2, kc3 = st.columns(3)
kc1.metric("Total Signups",   int(kpis["TOTAL_SIGNUPS"][0]))
kc2.metric("Conversion Rate", f'{kpis["CONVERSION_RATE"][0]}%')
kc3.metric("Total MRR",       f'${kpis["TOTAL_MRR"][0]:,.0f}')

st.divider()

# ── Charts: 3 equal columns on one row ─────────────────────────────────────
c1, c2, c3 = st.columns(3)

with c1:
    st.subheader("Signups by Channel")
    df_bar = session.sql("""
        SELECT SIGNUP_CHANNEL, COUNT(*) AS SIGNUPS
        FROM PM_AGENTS_DEMO.APP.SIGNUPS
        GROUP BY 1 ORDER BY 2 DESC
    """).to_pandas()
    st.bar_chart(df_bar.set_index("SIGNUP_CHANNEL"), use_container_width=True)

with c2:
    st.subheader("Revenue by Plan Type")
    df_pie = session.sql("""
        SELECT PLAN_TYPE, ROUND(SUM(MRR_AMOUNT), 2) AS REVENUE
        FROM PM_AGENTS_DEMO.APP.SIGNUPS
        WHERE CONVERTED_TO_PAID AND MRR_AMOUNT > 0
        GROUP BY 1
    """).to_pandas()
    pie = (
        alt.Chart(df_pie)
        .mark_arc(innerRadius=50)
        .encode(
            theta=alt.Theta("REVENUE:Q"),
            color=alt.Color("PLAN_TYPE:N", legend=alt.Legend(title="Plan")),
            tooltip=[
                alt.Tooltip("PLAN_TYPE:N", title="Plan"),
                alt.Tooltip("REVENUE:Q", title="Revenue", format="$,.0f"),
            ],
        )
        .properties(height=300)
    )
    st.altair_chart(pie, use_container_width=True)

with c3:
    st.subheader("Signups by Channel & Month")
    df_heat = session.sql("""
        SELECT
            TO_CHAR(DATE_TRUNC('month', SIGNUP_DATE), 'YYYY-MM') AS MONTH,
            SIGNUP_CHANNEL AS CHANNEL,
            COUNT(*) AS SIGNUPS
        FROM PM_AGENTS_DEMO.APP.SIGNUPS
        GROUP BY 1, 2
        ORDER BY 1, 2
    """).to_pandas()
    heatmap = (
        alt.Chart(df_heat)
        .mark_rect()
        .encode(
            x=alt.X("MONTH:O", title="Month", axis=alt.Axis(labelAngle=-45)),
            y=alt.Y("CHANNEL:N", title=None, sort="-x"),
            color=alt.Color(
                "SIGNUPS:Q",
                scale=alt.Scale(scheme="blues"),
                legend=alt.Legend(title="Signups"),
            ),
            tooltip=[
                alt.Tooltip("MONTH:O", title="Month"),
                alt.Tooltip("CHANNEL:N", title="Channel"),
                alt.Tooltip("SIGNUPS:Q", title="Signups"),
            ],
        )
        .properties(height=300)
    )
    st.altair_chart(heatmap, use_container_width=True)
