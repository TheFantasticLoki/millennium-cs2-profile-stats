import { definePlugin, Field, IconsModule, TextField, ToggleField, usePluginConfig } from '@steambrew/client';

const PROVIDERS = [
	{ name: 'leetify', label: 'Leetify', description: 'Performance ratings, aim, reaction time, and match history.' },
	{ name: 'faceit', label: 'FACEIT', description: 'FACEIT level, ELO, and match statistics.' },
	{ name: 'cstracker', label: 'CSTracker.GG', description: 'Trust rating, detailed stats, kill breakdown, and match history.' },
	{ name: 'csrep', label: 'CSRep.GG', description: 'Trust score with statistical breakdown and account flags.' },
	{ name: 'csstats', label: 'CSStats.GG', description: 'Match statistics, win rate, and K/D tracking.' },
	{ name: 'cs2tracker', label: 'CS2Tracker.GG', description: 'Cheating suspicion scores and Overwatch data.' },
	{ name: 'tracker', label: 'Tracker.GG', description: 'General CS2 statistics and leaderboard data.' },
] as const;

const SettingsContent = () => {
	const [leetifyApiKey, setLeetifyApiKey] = usePluginConfig<string>('leetify_api_key');
	const [showSteamDetails, setShowSteamDetails] = usePluginConfig<boolean>('show_steam_details');
	const [expandDetails, setExpandDetails] = usePluginConfig<boolean>('expand_details');
	const [flaresolverrUrl, setFlaresolverrUrl] = usePluginConfig<string>('flaresolverr_url');

	return (
		<div style={{ padding: '16px' }}>
			{/* General Settings */}
			<Field
				label="Leetify API key"
				description="Optional. Public requests work without a key, while a personal key provides better rate limits."
				icon={<IconsModule.Settings />}
				childrenLayout="below"
				bottomSeparator="standard"
			>
				<TextField
					value={leetifyApiKey ?? ''}
					onChange={(event) => void setLeetifyApiKey(event.currentTarget.value.trim())}
					bIsPassword
					bShowClearAction
					bAlwaysShowClearAction
				/>
			</Field>

			<ToggleField
				label="Show Steam activity"
				description="Show total CS2 hours, recent hours, and the Steam account creation date in the expanded view."
				checked={showSteamDetails ?? true}
				onChange={(checked) => void setShowSteamDetails(checked)}
				bottomSeparator="standard"
			/>

			<ToggleField
				label="Expand details by default"
				description="Open the detailed Leetify, FACEIT, and Steam metrics when a profile loads."
				checked={expandDetails ?? false}
				onChange={(checked) => void setExpandDetails(checked)}
				bottomSeparator="standard"
			/>

			<Field
				label="FlareSolverr URL"
				description="Optional. URL of a FlareSolverr instance (e.g. http://localhost:8191) to bypass Cloudflare protection on blocked providers."
				icon={<IconsModule.Settings />}
				childrenLayout="below"
				bottomSeparator="standard"
			>
				<TextField
					value={flaresolverrUrl ?? ''}
					onChange={(event) => void setFlaresolverrUrl(event.currentTarget.value.trim())}
					bShowClearAction
					bAlwaysShowClearAction
				/>
			</Field>

			{/* Provider Settings */}
			<div style={{ marginTop: '16px', marginBottom: '8px' }}>
				<strong style={{ fontSize: '14px', color: '#fff' }}>Data Providers</strong>
				<p style={{ fontSize: '12px', color: '#8ea6b7', margin: '4px 0 0' }}>
					Configure which stats providers to use. Disabling a provider stops it from fetching data.
				</p>
			</div>
			{PROVIDERS.map((provider) => (
				<ProviderToggle key={provider.name} provider={provider} />
			))}
		</div>
	);
};

const ProviderToggle = ({ provider }: { provider: { name: string; label: string; description: string } }) => {
	const [enabled, setEnabled] = usePluginConfig<boolean>(`provider_${provider.name}_enabled`);

	return (
		<ToggleField
			label={provider.label}
			description={provider.description}
			checked={enabled !== false}
			onChange={(checked) => void setEnabled(checked)}
			bottomSeparator="standard"
		/>
	);
};

export default definePlugin(() => ({
	title: 'CS2 Profile Stats',
	icon: <IconsModule.Settings />,
	content: <SettingsContent />,
}));
