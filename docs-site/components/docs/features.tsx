export function Features() {
	return (
		<div className="py-2 max-w-[1300px]">
			<div className="mt-2 grid grid-cols-1 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-3 gap-4 md:gap-3 max-w-7xl mx-auto">
				{grid.map((feature) => (
					<div
						key={feature.title}
						className="relative min-h-[180px] rounded-lg border border-neutral-200 bg-neutral-50 px-6 py-4 dark:border-neutral-800 dark:bg-neutral-900"
					>
						<p className="text-base font-bold text-neutral-800 dark:text-white">
							{feature.title}
						</p>
						<p className="text-neutral-600 dark:text-neutral-400 text-base font-normal mt-1">
							{feature.description}
						</p>
					</div>
				))}
			</div>
		</div>
	);
}

const grid = [
	{
		title: "Rack-native",
		description: "Mount on Rails, Sinatra, Roda, Grape, or plain Rack",
	},
	{
		title: "Email & Password",
		description: "Built-in sign-up, sign-in, password reset",
	},
	{
		title: "Sessions & Accounts",
		description: "Session cookies, list/revoke, OAuth account linking",
	},
	{
		title: "Rate limiting",
		description: "Built-in limiter with custom rules",
	},
	{
		title: "SQL migrations",
		description:
			"CLI generate / migrate for Postgres, MySQL, SQLite, MSSQL",
	},
	{
		title: "Social OAuth",
		description: "34 built-in providers",
	},
	{
		title: "Organizations",
		description:
			"Multi-tenant orgs plugin (see docs for parity notes)",
	},
	{
		title: "Two-factor auth",
		description: "TOTP plugin",
	},
	{
		title: "Plugin ecosystem",
		description: "Optional gems: api-key, passkey, SSO, Stripe, SCIM",
	},
];
