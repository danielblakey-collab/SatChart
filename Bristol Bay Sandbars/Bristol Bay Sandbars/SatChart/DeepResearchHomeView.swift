
//  DeepResearchHomeView.swift
//  SatChart
//
//  Created by Daniel Blakey on 3/13/26.
//

import SwiftUI

struct DeepResearchHomeView: View {
    var body: some View {
        ZStack {
            bbMenuBlue.ignoresSafeArea()

            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.15, blue: 0.30),
                    Color(red: 0.01, green: 0.08, blue: 0.18)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: [.top, .leading, .trailing])

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    NavigationLink {
                        DeepResearchView()
                    } label: {
                        ResearchLandingCard(
                            title: "Charts",
                            subtitle: "Visual analysis, comparisons and timing tools",
                            symbolName: "chart.xyaxis.line"
                        )
                    }
                    .buttonStyle(SatChartPressFeedbackButtonStyle())

                    NavigationLink {
                        DeepResearchTablesView()
                    } label: {
                        ResearchLandingCard(
                            title: "Tables",
                            subtitle: "Generate date-range tables and export CSV",
                            symbolName: "tablecells"
                        )
                    }
                    .buttonStyle(SatChartPressFeedbackButtonStyle())
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 0)
            }
        }
        .navigationTitle("Deep Research")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ResearchLandingCard: View {
    let title: String
    let subtitle: String
    let symbolName: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 52, height: 52)

                Image(systemName: symbolName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Text(subtitle)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.70))
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white.opacity(0.65))
        }
        .padding(14)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }
}

private struct DeepResearchTablesPlaceholderView: View {
    var body: some View {
        ZStack {
            bbMenuBlue.ignoresSafeArea()

            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.15, blue: 0.30),
                    Color(red: 0.01, green: 0.08, blue: 0.18)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: [.top, .leading, .trailing])

            VStack(spacing: 12) {
                Text("Tables")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Text("Deep Research tables are available from the current tables view when enabled for this build.")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .navigationTitle("Tables")
        .navigationBarTitleDisplayMode(.inline)
    }
}
