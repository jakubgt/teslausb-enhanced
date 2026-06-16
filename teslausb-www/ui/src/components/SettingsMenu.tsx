import Button from '@cloudscape-design/components/button';
import Popover from '@cloudscape-design/components/popover';
import SpaceBetween from '@cloudscape-design/components/space-between';
import Toggle from '@cloudscape-design/components/toggle';

interface SettingsMenuProps {
  darkMode: boolean;
  onDarkModeChange: (checked: boolean) => void;
}

export default function SettingsMenu({ darkMode, onDarkModeChange }: SettingsMenuProps) {
  return (
    <Popover
      dismissButton={false}
      position="bottom"
      size="medium"
      triggerType="custom"
      content={
        <SpaceBetween size="m" direction="vertical">
          <Toggle checked={darkMode} onChange={({ detail }) => onDarkModeChange(detail.checked)}>
            Dark Mode
          </Toggle>
          <Button iconName="refresh" onClick={() => window.location.reload()} fullWidth>
            Refresh Page
          </Button>
        </SpaceBetween>
      }
    >
      <Button iconName="settings" variant="inline-icon" ariaLabel="Settings" />
    </Popover>
  );
}
