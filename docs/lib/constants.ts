export const ENV = {
	NEXT_PUBLIC_WEBSITE_URL:
		process.env.NEXT_PUBLIC_WEBSITE_URL || "http://localhost:3000",
	NEXT_PUBLIC_GOOGLE_SITE_VERIFICATION: "",
	NODE_ENV: process.env.NODE_ENV || "development",
};

export const GITHUB_REPO = {
	owner: "sebasxsala",
	name: "better-auth-rb",
	url: "https://github.com/sebasxsala/better-auth-rb",
	apiUrl: "https://api.github.com/repos/sebasxsala/better-auth-rb",
};

export const SHOW_UPSTREAM_BLOG_CONTENT = false;
export const SHOW_UPSTREAM_CHANGELOG_CONTENT = true;
