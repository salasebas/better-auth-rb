export interface CommunityPlugin {
	name: string;
	url: string;
	description: string;
	author: {
		name: string;
		github: string;
		avatar: string;
	};
}

/** Ruby community plugins — populated as gems ship; upstream npm plugins removed in plan 020. */
export const communityPlugins: CommunityPlugin[] = [];
