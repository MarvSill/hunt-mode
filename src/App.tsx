import { lazy, Suspense, useState } from 'react';
import { NavLink, Navigate, Route, Routes, useLocation } from 'react-router-dom';
import Icon from './components/Icon';
import { useAuth } from './lib/auth';
import { supabase } from './lib/supabase';
import GamePage from './pages/Game';
import HomePage from './pages/Home';
import GroupPage from './pages/Group';
import GroupsPage from './pages/Groups';
import JoinPage from './pages/Join';
import IntroPage, { introSeen } from './pages/Intro';
import PrivacyPage from './pages/Privacy';

import LoginPage from './pages/Login';
import NewGamePage from './pages/NewGame';
import NewPasswordPage from './pages/NewPassword';
import OnboardingPage from './pages/Onboarding';
import ProfilePage from './pages/Profile';
import RulesPage from './pages/Rules';
import SetupMissingPage from './pages/SetupMissing';
import Loader from './components/Loader';
import { t } from './i18n';

// Karte und Spielansicht (Leaflet) erst bei Bedarf laden.
const MapEditorPage = lazy(() => import('./pages/MapEditor'));
const PlayPage = lazy(() => import('./play/Play'));

export default function App() {
  const { loading, session, profile, hasEmergencyContact, recovering } = useAuth();
  const location = useLocation();
  // Untere Leiste nur auf den Hauptseiten; in Spiel, Karte und Erstellen stört sie.
  const showNav = ['/', '/beitreten', '/gruppen', '/profil'].includes(location.pathname) || /^\/gruppen\//.test(location.pathname);
  const [introDone, setIntroDone] = useState(introSeen);

  if (!supabase) return <SetupMissingPage />;
  if (loading) return <Loader />;
  if (recovering) return <NewPasswordPage />;
  if (!session) {
    return (
      <Routes>
        <Route path="/beitreten/:code" element={<LoginPage />} />
        <Route path="/datenschutz" element={<PrivacyPage />} />
        <Route path="/hilfe" element={<IntroPage />} />
        <Route path="*" element={<LoginPage />} />
      </Routes>
    );
  }
  if (!profile || !profile.age_confirmed || !hasEmergencyContact) {
    if (location.pathname === '/datenschutz') return <PrivacyPage />;
    return <OnboardingPage />;
  }
  if (!introDone && !location.pathname.startsWith('/beitreten/')) return <IntroPage onDone={() => setIntroDone(true)} />;

  return (
    <>
      <Suspense fallback={<Loader />}>
      <Routes>
        <Route path="/" element={<HomePage />} />
        <Route path="/neu" element={<NewGamePage />} />
        <Route path="/neu/eigenes" element={<NewGamePage />} />
        <Route path="/beitreten" element={<JoinPage />} />
        <Route path="/beitreten/:code" element={<JoinPage />} />
        <Route path="/spiel/:id" element={<GamePage />} />
        <Route path="/spiel/:id/regeln" element={<RulesPage />} />
        <Route path="/spiel/:id/karte" element={<MapEditorPage />} />
        <Route path="/spiel/:id/live" element={<PlayPage />} />
        <Route path="/gruppen" element={<GroupsPage />} />
        <Route path="/gruppen/:id" element={<GroupPage />} />
        <Route path="/gruppe/:code" element={<GroupsPage />} />
        <Route path="/profil" element={<ProfilePage />} />
        <Route path="/hilfe" element={<IntroPage />} />
        <Route path="/datenschutz" element={<PrivacyPage />} />
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
      </Suspense>
      {showNav && <nav className="nav">
        <NavLink to="/" end><Icon name="home" />{t('Start')}</NavLink>
        <NavLink to="/beitreten"><Icon name="join" />{t('Beitreten')}</NavLink>
        <NavLink to="/gruppen"><Icon name="users" />{t('Gruppen')}</NavLink>
        <NavLink to="/profil"><Icon name="user" />{t('Profil')}</NavLink>
      </nav>}
    </>
  );
}
