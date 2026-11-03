#include "version-compare.hpp"

#include <QList>
#include <QStringList>

#include <cstdio>

static int failures = 0;

static void expect(const char *latest, const char *current, bool newer)
{
	if (op_version_is_newer(QString::fromLatin1(latest), QString::fromLatin1(current)) != newer) {
		fprintf(stderr, "FAIL: %s vs %s, expected %s\n", latest, current, newer ? "newer" : "not newer");
		failures++;
	}
}

static void expect_releases(const char *json, const char *current, OPUpdateResult::Status status, const char *version,
			    const char *notes_order)
{
	const OPUpdateResult r = op_evaluate_releases(QByteArray(json), QString::fromLatin1(current));
	bool ok = r.status == status && r.version == QString::fromLatin1(version);
	if (ok && notes_order) {
		/* Each "|"-separated heading must appear, in this order. */
		qsizetype at = -1;
		for (const QString &h : QString::fromLatin1(notes_order).split(QLatin1Char('|'))) {
			const qsizetype next = r.notes.indexOf(h, at + 1);
			if (next <= at) {
				ok = false;
				break;
			}
			at = next;
		}
	}
	if (!ok) {
		fprintf(stderr, "FAIL: releases %s (current %s): status=%d version=%s\n", json, current, (int)r.status,
			qPrintable(r.version));
		failures++;
	}
}

int main()
{
	const char *list =
		"[{\"tag_name\":\"v1.1.0\",\"body\":\"b110\",\"html_url\":\"https://github.com/Neotecos/obs-optimized-previews/releases/tag/v1.1.0\"},"
		"{\"tag_name\":\"v1.3.0\",\"body\":\"b130\"},"
		"{\"tag_name\":\"v1.2.0\",\"body\":\"b120\"},"
		"{\"tag_name\":\"v9.0.0\",\"prerelease\":true,\"body\":\"pre\"},"
		"{\"tag_name\":\"v8.0.0\",\"draft\":true,\"body\":\"draft\"},"
		"{\"tag_name\":\"v1.0.0\",\"body\":\"b100\"}]";
	using S = OPUpdateResult::Status;
	expect_releases(list, "1.0.0", S::Available, "1.3.0", "## 1.3.0|## 1.2.0|## 1.1.0");
	expect_releases(list, "1.2.0", S::Available, "1.3.0", "## 1.3.0");
	expect_releases(list, "1.3.0", S::UpToDate, "", nullptr);
	expect_releases(list, "2.0.0", S::UpToDate, "", nullptr);
	expect_releases("[]", "1.0.0", S::UpToDate, "", nullptr);
	expect_releases("{\"tag_name\":\"v1.1.0\"}", "1.0.0", S::Failed, "", nullptr);
	expect_releases("not json", "1.0.0", S::Failed, "", nullptr);
	{
		const OPUpdateResult r = op_evaluate_releases(QByteArray(list), QStringLiteral("1.0.0"));
		if (r.notes.contains(QStringLiteral("pre")) || r.notes.contains(QStringLiteral("draft")) ||
		    r.notes.contains(QStringLiteral("b100"))) {
			fprintf(stderr, "FAIL: prerelease, draft or installed notes leaked\n");
			failures++;
		}
		if (!r.url.startsWith(QLatin1String("https://github.com/Neotecos/"))) {
			fprintf(stderr, "FAIL: url not on the project repository\n");
			failures++;
		}
	}

	expect("1.1.0", "1.0.0", true);
	expect("v1.1.0", "1.0.0", true);
	expect("1.0.0", "1.0.0", false);
	expect("1.0.0", "1.1.0", false);
	expect("1.10.0", "1.9.0", true);
	expect("2.0", "1.9.9", true);
	expect("1.0", "1.0.0", false);
	expect("1.0.1", "1.0", true);
	expect("1.2.0-beta.1", "1.1.0", true);
	expect("1.1.0+build5", "1.1.0", false);
	expect("", "1.0.0", false);
	expect("latest", "1.0.0", false);
	expect("1.x", "1.0.0", false);
	expect("1.1.0", "dev", false);
	return failures ? 1 : 0;
}
