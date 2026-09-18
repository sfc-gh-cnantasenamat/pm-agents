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
        COUNT(*)                                                        AS total_signups,
        ROUND(
            SUM(CASE WHEN converted_to_paid THEN 1 ELSE 0 END)
            * 100.0 / NULLIF(COUNT(*), 0), 1)                          AS conversion_rate,
        ROUND(SUM(CASE WHEN converted_to_paid THEN mrr_amount
                       ELSE 0 END), 2)                                 AS total_mrr
    FROM PM_AGENTS_DEMO.APP.SIGNUPS
""").to_pandas()

kc1, kc2, kc3 = st.columns(3)
kc1.metric("Total Signups",   int(kpis["TOTAL_SIGNUPS"][0]))
kc2.metric("Conversion Rate", f'{kpis["CONVERSION_RATE"][0]}%')
kc3.metric("Total MRR",       f'${kpis["TOTAL_MRR"][0]:,.0f}')

st.divider()

# ── Row 1: three charts side by side ───────────────────────────────────────
r1c1, r1c2, r1c3 = st.columns(3)

with r1c1:
    st.subheader("Signups by Channel")
    df_ch = session.sql("""
        SELECT signup_channel AS channel, COUNT(*) AS signups
        FROM PM_AGENTS_DEMO.APP.SIGNUPS
        GROUP BY 1 ORDER BY 2 DESC
    """).to_pandas()
    st.bar_chart(df_ch.set_index("CHANNEL"), use_container_width=True)

with r1c2:
    st.subheader("Revenue by Plan Type")
    df_rev = session.sql("""
        SELECT plan_type, ROUND(SUM(mrr_amount), 2) AS revenue
        FROM PM_AGENTS_DEMO.APP.SIGNUPS
        WHERE converted_to_paid
        GROUP BY 1 ORDER BY 2 DESC
    """).to_pandas()
    st.bar_chart(df_rev.set_index("PLAN_TYPE"), use_container_width=True)

with r1c3:
    st.subheader("Plan Mix (% of MRR)")
    df_pie = session.sql("""
        SELECT plan_type, ROUND(SUM(mrr_amount), 2) AS revenue
        FROM PM_AGENTS_DEMO.APP.SIGNUPS
        WHERE converted_to_paid AND mrr_amount > 0
        GROUP BY 1
    """).to_pandas()
    pie = (
        alt.Chart(df_pie)
        .mark_arc(innerRadius=40)
        .encode(
            theta=alt.Theta("revenue:Q"),
            color=alt.Color("PLAN_TYPE:N", legend=alt.Legend(title="Plan")),
            tooltip=["PLAN_TYPE:N", alt.Tooltip("revenue:Q", format="$,.0f")],
        )
    )
    st.altair_chart(pie, use_container_width=True)

st.divider()

# ── Row 2: monthly trend (wider) + conversion by channel (narrower) ────────
r2c1, r2c2 = st.columns([2, 1])

with r2c1:
    st.subheader("Monthly Signup Trend")
    df_trend = session.sql("""
        SELECT
            TO_CHAR(DATE_TRUNC('month', signup_date), 'YYYY-MM') AS month,
            COUNT(*) AS signups
        FROM PM_AGENTS_DEMO.APP.SIGNUPS
        GROUP BY 1 ORDER BY 1
    """).to_pandas()
    trend_chart = (
        alt.Chart(df_trend)
        .mark_line(point=True)
        .encode(
            x=alt.X("month:O", title="Month", axis=alt.Axis(labelAngle=-45)),
            y=alt.Y("signups:Q", title="Signups"),
            tooltip=["month:O", "signups:Q"],
        )
    )
    st.altair_chart(trend_chart, use_container_width=True)

with r2c2:
    st.subheader("Conversion by Channel")
    df_conv = session.sql("""
        SELECT
            signup_channel AS channel,
            ROUND(SUM(CASE WHEN converted_to_paid THEN 1 ELSE 0 END)
                  * 100.0 / NULLIF(COUNT(*), 0), 1) AS conv_rate
        FROM PM_AGENTS_DEMO.APP.SIGNUPS
        GROUP BY 1 ORDER BY 2 DESC
    """).to_pandas()
    conv_chart = (
        alt.Chart(df_conv)
        .mark_bar()
        .encode(
            x=alt.X("conv_rate:Q", title="Conversion %"),
            y=alt.Y("CHANNEL:N", sort="-x", title=None),
            tooltip=["CHANNEL:N", alt.Tooltip("conv_rate:Q", format=".1f", title="Conv %")],
        )
    )
    st.altair_chart(conv_chart, use_container_width=True)

st.divider()

# ── Row 3: channel × month heatmap ─────────────────────────────────────────
st.subheader("Signups by Channel and Month")
df_heat = session.sql("""
    SELECT
        TO_CHAR(DATE_TRUNC('month', signup_date), 'YYYY-MM') AS month,
        signup_channel AS channel,
        COUNT(*) AS signups
    FROM PM_AGENTS_DEMO.APP.SIGNUPS
    GROUP BY 1, 2
""").to_pandas()

heatmap = (
    alt.Chart(df_heat)
    .mark_rect()
    .encode(
        x=alt.X("month:O", title="Month", axis=alt.Axis(labelAngle=-45)),
        y=alt.Y("CHANNEL:N", title=None),
        color=alt.Color(
            "signups:Q",
            scale=alt.Scale(scheme="blues"),
            legend=alt.Legend(title="Signups"),
        ),
        tooltip=["month:O", "CHANNEL:N", "signups:Q"],
    )
    .properties(height=200)
)
st.altair_chart(heatmap, use_container_width=True)
