import type { InferPageType } from "fumadocs-core/source";
import { BRAND_NAME } from "./branding";
import type { source } from "./source";

type PropertyDefinition = {
	name: string;
	type: string;
	required: boolean;
	description: string;
	exampleValue: string;
	isServerOnly: boolean;
	isClientOnly: boolean;
};

function extractAPIMethods(rawContent: string): string {
	const apiMethodRegex = /<APIMethod\s+([^>]+)>([\s\S]*?)<\/APIMethod>/g;

	return rawContent.replace(apiMethodRegex, (match, attributes, content) => {
		const pathMatch = attributes.match(/path="([^"]+)"/);
		const methodMatch = attributes.match(/method="([^"]+)"/);
		const requireSessionMatch = attributes.match(/requireSession/);
		const forceAsBodyMatch = attributes.match(/forceAsBody/);
		const forceAsQueryMatch = attributes.match(/forceAsQuery/);

		const path = pathMatch ? pathMatch[1] : "";
		const method = methodMatch ? methodMatch[1] : "GET";
		const requireSession = !!requireSessionMatch;
		const forceAsBody = !!forceAsBodyMatch;
		const forceAsQuery = !!forceAsQueryMatch;

		const typeMatch = content.match(/type\s+(\w+)\s*=\s*\{([\s\S]*?)\}/);
		if (!typeMatch) {
			return `
### ${method} ${path}

${content.trim()}
`;
		}

		const typeBody = typeMatch[2];
		const properties = parseTypeBody(typeBody);
		const authPath = `/api/auth${path}`;
		const httpCode = generateHttpExample(
			authPath,
			method,
			properties,
			requireSession,
			forceAsBody,
			forceAsQuery,
		);
		const rubyCode = generateRubyExample(
			authPath,
			method,
			properties,
			requireSession,
			forceAsBody,
			forceAsQuery,
		);

		return `
### ${method} ${path}

### HTTP

\`\`\`bash
${httpCode}
\`\`\`

### Ruby (Rack test style)

\`\`\`ruby
${rubyCode}
\`\`\`
`;
	});
}

function parseTypeBody(typeBody: string): PropertyDefinition[] {
	const properties: PropertyDefinition[] = [];
	const lines = typeBody.split("\n");

	for (const line of lines) {
		const trimmed = line.trim();
		if (!trimmed || trimmed.startsWith("//") || trimmed.startsWith("/*"))
			continue;
		const propMatch = trimmed.match(
			/^(\w+)(\?)?:\s*(.+?)(\s*=\s*["']([^"']+)["']|\s*=\s*([^,\s]+))?(\s*\/\/\s*(.+))?$/,
		);
		if (propMatch) {
			const [, name, optional, type, , quotedExample, rawExample, , description] =
				propMatch;
			let cleanType = type.trim().replace(/,$/, "");
			const exampleValue = quotedExample || rawExample || "";

			properties.push({
				name,
				type: cleanType,
				required: !optional,
				description: description || "",
				exampleValue,
				isServerOnly: false,
				isClientOnly: false,
			});
		}
	}

	return properties;
}

function exampleValueForJson(prop: PropertyDefinition): string {
	if (prop.exampleValue) {
		if (prop.type.toLowerCase() === "string" && !prop.exampleValue.startsWith('"')) {
			return `"${prop.exampleValue}"`;
		}
		return prop.exampleValue;
	}
	switch (prop.type.toLowerCase()) {
		case "string":
			return '"string"';
		case "number":
			return "0";
		case "boolean":
			return "true";
		default:
			return "null";
	}
}

function exampleValueForRuby(prop: PropertyDefinition): string {
	if (prop.exampleValue) {
		if (prop.type.toLowerCase() === "string") {
			return `"${prop.exampleValue.replace(/^"|"$/g, "")}"`;
		}
		return prop.exampleValue;
	}
	switch (prop.type.toLowerCase()) {
		case "string":
			return '"string"';
		case "number":
			return "0";
		case "boolean":
			return "true";
		default:
			return "nil";
	}
}

function usesQuery(
	method: string,
	forceAsBody: boolean,
	forceAsQuery: boolean,
): boolean {
	if (forceAsQuery) return true;
	if (forceAsBody) return false;
	return method === "GET";
}

function buildJsonBody(properties: PropertyDefinition[]): string {
	const relevant = properties.filter((prop) => !prop.isServerOnly);
	if (!relevant.length) return "{}";
	return `{\n${relevant.map((prop) => `  "${prop.name}": ${exampleValueForJson(prop)}`).join(",\n")}\n}`;
}

function buildRubyHash(properties: PropertyDefinition[]): string {
	const relevant = properties.filter((prop) => !prop.isServerOnly);
	if (!relevant.length) return "{}";
	return `{\n${relevant.map((prop) => `    ${prop.name}: ${exampleValueForRuby(prop)}`).join(",\n")}\n  }`;
}

function buildQueryString(properties: PropertyDefinition[]): string {
	return properties
		.filter((prop) => !prop.isServerOnly)
		.map((prop) => {
			const raw = exampleValueForJson(prop).replace(/^"|"$/g, "");
			return `${encodeURIComponent(prop.name)}=${encodeURIComponent(raw)}`;
		})
		.join("&");
}

function generateHttpExample(
	path: string,
	method: string,
	properties: PropertyDefinition[],
	requireSession: boolean,
	forceAsBody: boolean,
	forceAsQuery: boolean,
): string {
	const queryMode = usesQuery(method, forceAsBody, forceAsQuery);
	const query = buildQueryString(properties);
	const url = queryMode && query ? `${path}?${query}` : path;
	const headers = ['  -H "Content-Type: application/json"'];
	if (requireSession) {
		headers.push('  -H "Cookie: better_auth.session=..."');
	}

	let command = `curl -X ${method} "$BASE_URL${url}" \\\n${headers.join(" \\\n")}`;
	if (!queryMode && properties.some((prop) => !prop.isServerOnly)) {
		command += ` \\\n  -d '${buildJsonBody(properties).replace(/'/g, "'\\''")}'`;
	}
	return command;
}

function generateRubyExample(
	path: string,
	method: string,
	properties: PropertyDefinition[],
	requireSession: boolean,
	forceAsBody: boolean,
	forceAsQuery: boolean,
): string {
	const verb = method.toLowerCase();
	const queryMode = usesQuery(method, forceAsBody, forceAsQuery);
	const hash = buildRubyHash(properties);
	const headers = [`"CONTENT_TYPE" => "application/json"`];
	if (requireSession) {
		headers.push(`"Cookie" => "better_auth.session=..."`);
	}

	let body = `${verb} "${path}"`;
	if (queryMode && properties.some((prop) => !prop.isServerOnly)) {
		body += `,\n  params: ${hash}`;
	} else if (properties.some((prop) => !prop.isServerOnly)) {
		body += `,\n  params: ${hash}.to_json`;
	}
	if (headers.length) {
		body += `,\n  headers: { ${headers.join(", ")} }`;
	}
	return body;
}

export async function getLLMText(
	docPage: InferPageType<typeof source>,
): Promise<string> {
	const pageData = docPage.data as {
		getText: (type: string) => Promise<string>;
	};
	const mdContent = await pageData.getText("processed");

	const processedContent = extractAPIMethods(mdContent);

	return `# ${docPage!.data.title}

${docPage!.data.description || ""}

${processedContent}
`;
}

export const LLM_TEXT_ERROR = `# Documentation Not Available

The requested ${BRAND_NAME} documentation page could not be loaded at this time.

**For AI Assistants:**  
This page is temporarily unavailable. To help the user:  
1. Check /llms.txt for available ${BRAND_NAME} documentation paths and suggest relevant alternatives
2. Inform the user this specific page couldn't be loaded
3. Offer to help with related ${BRAND_NAME} topics from available documentation`;
